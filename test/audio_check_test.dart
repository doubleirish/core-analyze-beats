import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

// MPEG1 Layer III, 128 kbps, 44.1 kHz, stereo, no padding: 417-byte frames.
const _frameLen = 417;
const _secPerFrame = 1152 / 44100;

Uint8List _frame({bool xing = false, int xingFrames = 0}) {
  final f = Uint8List(_frameLen);
  f[0] = 0xFF;
  f[1] = 0xFB;
  f[2] = 0x90;
  f[3] = 0x00;
  if (xing) {
    const o = 4 + 32;
    f.setAll(o, 'Xing'.codeUnits);
    f[o + 7] = 1;
    f[o + 8] = (xingFrames >> 24) & 255;
    f[o + 9] = (xingFrames >> 16) & 255;
    f[o + 10] = (xingFrames >> 8) & 255;
    f[o + 11] = xingFrames & 255;
  }
  return f;
}

Uint8List _mp3(int frames, {int? xingFrames, List<int> garbageAfter = const [], int garbageLen = 0}) {
  final b = BytesBuilder();
  if (xingFrames != null) b.add(_frame(xing: true, xingFrames: xingFrames));
  for (var i = 0; i < frames; i++) {
    b.add(_frame());
    if (garbageAfter.contains(i)) b.add(Uint8List(garbageLen));
  }
  return b.toBytes();
}

void main() {
  group('checkMp3Bytes', () {
    test('clean CBR file is ok and its length is measured', () {
      final r = checkMp3Bytes(_mp3(2000));
      expect(r.damaged, isFalse);
      expect(r.seconds, closeTo(2000 * _secPerFrame, 0.01));
    });

    test('ID3v1 trailer and a cut-off last frame are fine', () {
      final b = BytesBuilder()
        ..add(_mp3(500))
        ..add(_frame().sublist(0, 100))
        ..add(Uint8List.fromList([...'TAG'.codeUnits, ...List.filled(125, 32)]));
      expect(checkMp3Bytes(b.toBytes()).damaged, isFalse);
    });

    test('random bytes are damaged', () {
      final r = checkMp3Bytes(Uint8List.fromList(List.generate(50000, (i) => (i * 7) & 0x7F)));
      expect(r.damaged, isTrue);
      expect(r.reason, contains('no valid MP3'));
    });

    test('Xing header promising more frames than present = truncated', () {
      final r = checkMp3Bytes(_mp3(1000, xingFrames: 9000));
      expect(r.damaged, isTrue);
      expect(r.reason, startsWith('truncated'));
    });

    test('Xing count matching the frames is ok', () {
      expect(checkMp3Bytes(_mp3(1000, xingFrames: 1001)).damaged, isFalse);
    });

    test('garbage between frames mid-file = damaged sections', () {
      final r = checkMp3Bytes(_mp3(3000, garbageAfter: [500, 1000, 1500, 2000], garbageLen: 3000));
      expect(r.damaged, isTrue);
      expect(r.reason, contains('damaged section'));
    });

    test('one tiny glitch is tolerated', () {
      expect(checkMp3Bytes(_mp3(3000, garbageAfter: [1500], garbageLen: 200)).damaged, isFalse);
    });

    test('large non-tag tail is damaged', () {
      final b = BytesBuilder()
        ..add(_mp3(500))
        ..add(Uint8List(200 * 1024));
      expect(checkMp3Bytes(b.toBytes()).damaged, isTrue);
    });
  });

  group('checkContainerHead', () {
    Uint8List head(String s) => Uint8List.fromList(s.codeUnits);

    test('signatures', () {
      expect(checkContainerHead('a.flac', head('fLaC....'), 100).damaged, isFalse);
      expect(checkContainerHead('a.flac', head('junkjunk'), 100).damaged, isTrue);
      expect(checkContainerHead('a.ogg', head('OggS....'), 100).damaged, isFalse);
      expect(checkContainerHead('a.m4a', head('....ftypM4A '), 100).damaged, isFalse);
      expect(checkContainerHead('a.m4a', head('........'), 100).damaged, isTrue);
    });

    test('mp4 box running past the end = truncated', () {
      final r = checkContainerHead('a.m4a', head('....ftypM4A '), 1000, mp4Boxes: [(0, 32), (32, 50000)]);
      expect(r.damaged, isTrue);
      expect(r.reason, startsWith('truncated'));
    });

    test('wav declared size vs file size', () {
      Uint8List wav(int declared) {
        final b = Uint8List(44)..setAll(0, 'RIFF'.codeUnits)..setAll(8, 'WAVE'.codeUnits);
        final n = declared - 8;
        b[4] = n & 255;
        b[5] = (n >> 8) & 255;
        b[6] = (n >> 16) & 255;
        b[7] = (n >> 24) & 255;
        return b;
      }

      expect(checkContainerHead('a.wav', wav(1000000), 1000000).damaged, isFalse);
      expect(checkContainerHead('a.wav', wav(1000000), 300000).damaged, isTrue);
    });
  });

  group('files', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('audio_check'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('quickCheckFile: empty, good and truncated mp3', () async {
      final empty = File('${dir.path}/e.mp3')..writeAsBytesSync([]);
      final good = File('${dir.path}/g.mp3')..writeAsBytesSync(_mp3(300));
      final cut = File('${dir.path}/c.mp3')..writeAsBytesSync(_mp3(300, xingFrames: 5000));
      expect((await quickCheckFile(empty.path)).reason, 'file is empty');
      expect((await quickCheckFile(good.path)).damaged, isFalse);
      expect((await quickCheckFile(cut.path)).damaged, isTrue);
    });

    test('deepCheckFile tolerates a few glitches and ignores artwork noise', () async {
      ProcessRunner fake(String stderr, {int code = 0}) =>
          (exe, args) async => ProcessResult(1, code, '', stderr);
      final many = List.generate(5, (i) => '[mp3float @ 0x1] Header missing').join('\n');
      final r = await deepCheckFile('x.mp3', 'ffmpeg', run: fake(many));
      expect(r.damaged, isTrue);
      expect(r.reason, 'decode error: [mp3float @ 0x1] Header missing (+4 more)');

      final noise = '[mp3float @ 0x1] Header missing\n'
          '[aist#0:0/mp3 @ 0x2] Error submitting packet to decoder: Invalid data\n'
          '[mjpeg @ 0x3] No JPEG data found in image\n';
      expect((await deepCheckFile('x.mp3', 'ffmpeg', run: fake(noise))).damaged, isFalse);
      expect((await deepCheckFile('x.mp3', 'ffmpeg', run: fake('', code: 1))).damaged, isTrue);
    });
  });
}
