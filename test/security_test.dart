import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/services/mixtape/http_transport.dart';
import 'package:shared_core/services/mixtape/manifest.dart';

Map<String, dynamic> _manifest({String id = 'abc123', List<Map<String, dynamic>>? tracks}) => {
      'format': mixtapeFormat,
      'version': mixtapeVersion,
      'id': id,
      'name': 'Mix',
      'transport': Transport.pull,
      'createdAt': 1,
      'tracks': tracks ??
          [
            {'file': 'songs/001 - A - Don\'t Stop.mp3', 'sha256': 'x', 'size': 10}
          ],
    };

void main() {
  group('manifest validation', () {
    test('accepts a normal manifest', () {
      expect(MixtapeManifest.fromJson(_manifest()).tracks.single.size, 10);
    });

    test('rejects ids that are not plain names', () {
      for (final id in ['../x', 'a b', "a'; rm -rf /", '..', '']) {
        expect(() => MixtapeManifest.fromJson(_manifest(id: id)), throwsFormatException, reason: id);
      }
    });

    test('rejects escaping paths, duplicates and bad sizes', () {
      Map<String, dynamic> t(String file, {int size = 1, String? art}) =>
          {'file': file, 'sha256': 'x', 'size': size, 'art': ?art};
      for (final tracks in [
        [t('../evil.mp3')],
        [t('songs/a.mp3', art: '/etc/passwd')],
        [t('songs/a.mp3'), t('songs/a.mp3')],
        [t('songs/a.mp3', size: -1)],
        [t('songs/a.mp3', size: maxTrackBytes + 1)],
      ]) {
        expect(() => MixtapeManifest.fromJson(_manifest(tracks: tracks)), throwsFormatException);
      }
    });

    test('rejects an unknown transport label and too many tracks', () {
      expect(() => MixtapeManifest.fromJson(_manifest()..['transport'] = 'evil'), throwsFormatException);
      final many = [
        for (var i = 0; i <= maxManifestTracks; i++) {'file': 'songs/$i.mp3', 'sha256': 'x', 'size': 1}
      ];
      expect(() => MixtapeManifest.fromJson(_manifest(tracks: many)), throwsFormatException);
    });
  });

  test('doneReport keeps only bounded, typed fields', () {
    final r = doneReport({
      'copied': 3,
      'reused': -5,
      'errors': ['a' * 1000, 42, ...List.filled(100, 'e')],
      'evil': {'x': 1},
    });
    expect(r.keys, ['copied', 'reused', 'errors']);
    expect(r['copied'], 3);
    expect(r['reused'], 0);
    expect((r['errors'] as List).length, 49);
    expect(((r['errors'] as List).first as String).length, 301);
  });

  test('isLanPeer allows private and loopback addresses only', () {
    for (final a in ['127.0.0.1', '10.1.2.3', '172.16.0.1', '192.168.1.5', '100.64.0.1']) {
      expect(isLanPeer(InternetAddress(a)), isTrue, reason: a);
    }
    for (final a in ['8.8.8.8', '172.32.0.1', '1.2.3.4']) {
      expect(isLanPeer(InternetAddress(a)), isFalse, reason: a);
    }
  });

  group('servers', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('sec_'));
    tearDown(() => tmp.delete(recursive: true));

    Future<int> post(int port, String path, List<int> body, {String token = '654321'}) async {
      final c = HttpClient();
      try {
        final req = await c.post('127.0.0.1', port, path);
        req.headers.set('x-token', token);
        req.contentLength = body.length;
        req.add(body);
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      } on SocketException {
        return -1; // server closed the connection while we were still sending
      } on HttpException {
        return -1;
      } finally {
        c.close(force: true);
      }
    }

    test('an oversized journal body is refused, not buffered', () async {
      var called = false;
      final server = PullServer(root: tmp, token: '654321', onJournal: (e) async {
        called = true;
        return 0;
      });
      await server.start(port: 0);
      addTearDown(server.stop);
      final status = await post(server.port!, '/pull/v1/journal', List.filled(maxJsonBody + 10, 32));
      expect(status, anyOf(413, -1));
      expect(called, isFalse);
    });

    test('the token is only accepted in the header', () async {
      final server = PullServer(root: tmp, token: '654321', onJournal: (e) async => 0);
      await server.start(port: 0);
      addTearDown(server.stop);
      final c = HttpClient();
      addTearDown(() => c.close(force: true));
      final req = await c.post('127.0.0.1', server.port!, '/pull/v1/journal?t=654321');
      req.write(jsonEncode({'entries': []}));
      final res = await req.close();
      await res.drain<void>();
      expect(res.statusCode, 401);
      expect(await post(server.port!, '/pull/v1/journal', utf8.encode('{"entries":[]}')), 200);
    });
  });
}
