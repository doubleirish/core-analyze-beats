import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_core/models/lyrics.dart';
import 'package:shared_core/services/enrich_service.dart';
import 'package:shared_core/services/tags.dart';
import 'package:shared_core/services/lyrics_sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _TestSource extends LyricsSource {
  const _TestSource(this.id, this.synced, this.run);
  @override
  final String id;
  @override
  String get name => id;
  @override
  final bool synced;
  final Future<String?> Function() run;

  @override
  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token}) => run();
}

Uint8List frame(String id, List<int> body) {
  final b = BytesBuilder()
    ..add(id.codeUnits)
    ..add([(body.length >> 21) & 0x7F, (body.length >> 14) & 0x7F, (body.length >> 7) & 0x7F, body.length & 0x7F])
    ..add([0, 0])
    ..add(body);
  return b.toBytes();
}

Uint8List id3(List<Uint8List> frames) {
  final body = BytesBuilder();
  for (final f in frames) {
    body.add(f);
  }
  final n = body.length;
  final b = BytesBuilder()
    ..add([0x49, 0x44, 0x33, 4, 0, 0])
    ..add([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])
    ..add(body.toBytes());
  return b.toBytes();
}

void main() {
  test('lyrics prefers high-yield sources but preserves synced-first fallback', () async {
    final order = <String>[];
    final service = EnrichService(
      lyricsSources: [
        _TestSource('miss', true, () async {
          order.add('miss');
          return null;
        }),
        _TestSource('hit', true, () async {
          order.add('hit');
          return '[00:01.00]lyrics';
        }),
        _TestSource('plain', false, () async {
          order.add('plain');
          return 'lyrics';
        }),
      ],
    );
    final tags = tagsFromFilename(r'C:\music\Artist - Song.mp3');
    expect((await service.fetchLyricsHit(tags))!.synced, isTrue);
    expect(order, ['miss', 'hit']);
    order.clear();
    await service.fetchLyricsHit(tags);
    expect(order, ['hit']);
    order.clear();
    service.resetSourceFailures();
    await service.fetchLyricsHit(tags);
    expect(order, ['miss', 'hit']);
  });

  test('lyrics skips repeatedly failing sources until a scan reset', () async {
    var calls = 0;
    final service = EnrichService(
      lyricsSources: [
        _TestSource('dead', true, () async {
          calls++;
          throw const HttpException('offline');
        }),
      ],
    );
    final tags = tagsFromFilename(r'C:\music\Artist - Song.mp3');
    for (var i = 0; i < EnrichService.maxSourceFailures + 1; i++) {
      await expectLater(service.fetchLyricsHit(tags), throwsA(isA<HttpException>()));
    }
    expect(calls, EnrichService.maxSourceFailures);
    service.resetSourceFailures();
    await expectLater(service.fetchLyricsHit(tags), throwsA(isA<HttpException>()));
    expect(calls, EnrichService.maxSourceFailures + 1);
  });

  test('LRC parser: stamps, multiple stamps, offset, lookup', () {
    final l = Lyrics.parse('[ar:X]\n[offset:500]\n[00:10.00]first\n[00:20.50][00:40.5]chorus\n[01:00]end');
    expect(l.synced, isTrue);
    expect(l.lines.length, 4);
    expect(l.lines.first.time, closeTo(9.5, 1e-6));
    expect(l.indexAt(5), -1);
    expect(l.indexAt(25), 1);
    expect(l.lines[2].text, 'chorus');
    expect(l.indexAt(1000), 3);
  });

  test('plain lyrics have no timing', () {
    final l = Lyrics.parse('\nhello\nworld');
    expect(l.synced, isFalse);
    expect(l.lines.length, 2);
    expect(l.indexAt(10), -1);
  });

  test('ID3 parser reads text, USLT and APIC (utf8 and utf16)', () {
    final img = List<int>.generate(20, (i) => i + 1);
    final bytes = id3([
      frame('TIT2', [3, ...utf8.encode('Song')]),
      frame('TPE1', [
        1,
        0xFF,
        0xFE,
        ...'Ärt'.codeUnits.expand((c) => [c, 0]),
      ]),
      frame('TALB', [0, ...latin1.encode('Alb')]),
      frame('USLT', [3, ...'eng'.codeUnits, 0, ...utf8.encode('la la')]),
      frame('APIC', [0, ...'image/jpeg'.codeUnits, 0, 3, 0, ...img]),
    ]);
    final t = parseId3v2(Uint8List.sublistView(bytes, 0, 10), Uint8List.sublistView(bytes, 10));
    expect(t.title, 'Song');
    expect(t.artist, 'Ärt');
    expect(t.album, 'Alb');
    expect(t.lyrics, 'la la');
    expect(t.picture, img);
  });

  test('filename fallback', () {
    final t = tagsFromFilename(r'C:\m\03 - Daft Punk - One More Time.mp3');
    expect(t.artist, 'Daft Punk');
    expect(t.title, 'One More Time');
    expect(tagsFromFilename('/m/Just Title.mp3').title, 'Just Title');
  });

  group('enrich', () {
    late Directory dir;
    late String mp3;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('enrich');
      mp3 = '${dir.path}${Platform.pathSeparator}Artist - Title.mp3';
      File(mp3).writeAsBytesSync([0, 0, 0]);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    MockClient client(List<String> log, {bool found = true}) => MockClient((req) async {
      log.add(req.url.host + req.url.path);
      if (req.url.host == 'lrclib.net') {
        return found
            ? http.Response(jsonEncode({'syncedLyrics': '[00:01.00]hi', 'plainLyrics': 'hi'}), 200)
            : http.Response('{}', 404);
      }
      if (req.url.host == 'itunes.apple.com') {
        return http.Response(
          jsonEncode({
            'results': [
              {'artistName': 'Artist', 'artworkUrl100': 'https://img.test/a/100x100bb.jpg'},
            ],
          }),
          200,
        );
      }
      if (req.url.host == 'img.test') {
        return http.Response.bytes(List.filled(2000, 7), 200);
      }
      return http.Response('', 404);
    });

    test('saves lyrics and per-song art, then skips on rerun', () async {
      final log = <String>[];
      final svc = EnrichService(client: client(log), minGap: Duration.zero);
      final r = await svc.enrich(mp3);
      expect(r.lyricsSaved, isTrue);
      expect(r.artSaved, isTrue);
      expect(File('$mp3.lrc').readAsStringSync(), contains('[00:01.00]hi'));
      expect(File('$mp3.jpg').existsSync(), isTrue); // no album tag: per-song art
      final calls = log.length;
      final again = await svc.enrich(mp3);
      expect(again.notes, ['already attempted']);
      expect(log.length, calls);
      expect(await EnrichService.localArt(mp3), isNotNull);
      expect((await EnrichService.localLyrics(mp3))!.synced, isTrue);
    });

    test('not found is remembered; force retries', () async {
      final log = <String>[];
      final svc = EnrichService(client: client(log, found: false), minGap: Duration.zero);
      final r = await svc.enrich(mp3);
      expect(r.lyricsSaved, isFalse);
      expect(File('$mp3.lrc').existsSync(), isFalse);
      expect(File('$mp3.enrich').existsSync(), isTrue);
      final n = log.length;
      await svc.enrich(mp3);
      expect(log.length, n);
      await svc.enrich(mp3, force: true);
      expect(log.length, greaterThan(n));
    });

    test('network failure is not remembered', () async {
      final svc = EnrichService(
        client: MockClient((_) async => throw const SocketException('offline')),
        minGap: Duration.zero,
      );
      final r = await svc.enrich(mp3);
      expect(r.notes.any((n) => n.contains('failed')), isTrue);
      expect(File('$mp3.enrich').existsSync(), isFalse);
    });

    test('existing local lyrics are not re-fetched', () async {
      File('${mp3.substring(0, mp3.length - 4)}.lrc').writeAsStringSync('[00:01.00]mine');
      final log = <String>[];
      final svc = EnrichService(client: client(log), minGap: Duration.zero);
      await svc.enrich(mp3);
      expect(log.where((l) => l.startsWith('lrclib')), isEmpty);
    });
  });
}
