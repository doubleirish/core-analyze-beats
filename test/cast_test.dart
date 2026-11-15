import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

void main() {
  const msg = CastMessage(
      sourceId: 'sender-0',
      destinationId: 'receiver-0',
      namespace: 'urn:x-cast:com.google.cast.receiver',
      payload: '{"type":"GET_STATUS","requestId":1,"t":"é"}');

  test('frames round-trip, also when split and concatenated', () {
    final frame = encodeCastFrame(msg);
    final r = CastFrameReader();
    expect(r.add(frame.sublist(0, 3)), isEmpty);
    expect(r.add(frame.sublist(3, 20)), isEmpty);
    final out = r.add([...frame.sublist(20), ...frame]);
    expect(out, hasLength(2));
    for (final m in out) {
      expect(m.sourceId, msg.sourceId);
      expect(m.destinationId, msg.destinationId);
      expect(m.namespace, msg.namespace);
      expect(m.payload, msg.payload);
    }
  });

  test('long payloads use multi-byte lengths', () {
    final big = CastMessage(
        sourceId: 'a', destinationId: 'b', namespace: 'c', payload: 'x' * 70000);
    final out = CastFrameReader().add(encodeCastFrame(big));
    expect(out.single.payload.length, 70000);
  });

  test('byte ranges', () {
    expect(parseByteRange('bytes=0-99', 1000), (0, 99));
    expect(parseByteRange('bytes=900-', 1000), (900, 999));
    expect(parseByteRange('bytes=-100', 1000), (900, 999));
    expect(parseByteRange('bytes=990-5000', 1000), (990, 999));
    expect(parseByteRange('bytes=1000-', 1000), isNull);
    expect(parseByteRange(null, 1000), isNull);
    expect(parseByteRange('garbage', 1000), isNull);
  });

  test('TXT record parsing', () {
    final m = parseCastTxt('id=abc123\nfn=Living Room\nmd=Chromecast Audio');
    expect(m['fn'], 'Living Room');
    expect(m['md'], 'Chromecast Audio');
  });

  test('media status parsing', () {
    final s = CastMediaStatus.fromJson({
      'status': [
        {
          'mediaSessionId': 3,
          'playerState': 'IDLE',
          'idleReason': 'FINISHED',
          'currentTime': 12.5,
          'media': {'duration': 200.0}
        }
      ]
    })!;
    expect(s.mediaSessionId, 3);
    expect(s.idleReason, 'FINISHED');
    expect(s.duration, 200.0);
    expect(CastMediaStatus.fromJson({'status': []}), isNull);
  });

  test('decoder ignores garbage', () {
    expect(decodeCastMessage(Uint8List.fromList([0xff, 0xff])), isNull);
  });

  test('lyrics become bounded, escaped WebVTT cues', () {
    final vtt = lyricsToVtt(Lyrics([
      const LyricLine(1.5, 'Hello <b> & you'),
      const LyricLine(4, ''),
      const LyricLine(4, 'Twice'),
      const LyricLine(100, 'Last'),
    ], synced: true))!;
    expect(vtt, startsWith('WEBVTT\n\n'));
    expect(vtt, contains('00:00:01.500 --> 00:00:04.000\nHello &lt;b&gt; &amp; you'));
    expect(vtt, contains('00:00:04.000 --> 00:00:16.000\nTwice'));
    expect(vtt, contains('00:01:40.000 --> 00:01:46.000\nLast'));
    expect(lyricsToVtt(Lyrics([const LyricLine(0, 'plain')], synced: false)), isNull);
    expect(lyricsToVtt(null), isNull);
  });

  test('image types come from the bytes', () {
    expect(sniffImageType([0xff, 0xd8, 0xff, 0xe0]), 'image/jpeg');
    expect(sniffImageType([0x89, 0x50, 0x4e, 0x47, 0, 0]), 'image/png');
    expect(sniffImageType([1, 2, 3]), isNull);
  });

  test('server serves registered art and text only, with their types', () async {
    final dir = await Directory.systemTemp.createTemp('cast_srv');
    final server = CastMediaServer();
    try {
      final art = File('${dir.path}/cover.img')..writeAsBytesSync([0xff, 0xd8, 0xff, 0xe0, 1, 2]);
      final other = File('${dir.path}/notes.txt')..writeAsStringSync('secret');
      await server.start();
      final artUrl = (await server.imageUrl(art.path, '127.0.0.1'))!;
      expect(await server.imageUrl(other.path, '127.0.0.1'), isNull);
      final vttUrl = server.textUrl('k', 'WEBVTT\n', 'text/vtt', '127.0.0.1');

      final c = HttpClient();
      final a = await (await c.getUrl(Uri.parse(artUrl))).close();
      expect(a.statusCode, 200);
      expect(a.headers.contentType?.mimeType, 'image/jpeg');
      await a.drain();
      final v = await (await c.getUrl(Uri.parse(vttUrl))).close();
      expect(v.headers.contentType?.mimeType, 'text/vtt');
      expect(await v.transform(utf8.decoder).join(), 'WEBVTT\n');
      final bad = await (await c.getUrl(Uri.parse(artUrl.replaceFirst(RegExp(r'/m/\w+/'), '/m/nope/')))).close();
      expect(bad.statusCode, 404);
      await bad.drain();
      c.close();
    } finally {
      await server.stop();
      await dir.delete(recursive: true);
    }
  });
}
