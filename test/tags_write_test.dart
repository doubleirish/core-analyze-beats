import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

Uint8List frame(String id, List<int> body, {int ver = 3}) {
  final n = body.length;
  final size = ver == 4
      ? [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F]
      : [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF];
  return Uint8List.fromList([...id.codeUnits, ...size, 0, 0, ...body]);
}

Uint8List tag(int ver, List<Uint8List> frames, {int pad = 0}) {
  final body = [for (final f in frames) ...f, ...List.filled(pad, 0)];
  final n = body.length;
  return Uint8List.fromList(
      [0x49, 0x44, 0x33, ver, 0, 0, (n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F, ...body]);
}

void main() {
  for (final ver in [3, 4]) {
    test('ID3v2.$ver: replaces title/artist/album, keeps other frames byte for byte', () {
      final apic = frame('APIC', List.generate(40, (i) => i), ver: ver);
      final old = tag(ver, [
        frame('TIT2', [0, ...'Old'.codeUnits], ver: ver),
        apic,
        frame('TCON', [0, ...'Tango'.codeUnits], ver: ver),
      ], pad: 100);

      final out = buildId3Tag(old, title: 'Libertango', album: 'Perfect Tango')!;
      final t = parseId3v2(out.sublist(0, 10), out.sublist(10));
      expect(t.title, 'Libertango');
      expect(t.album, 'Perfect Tango');
      expect(t.genre, 'Tango');
      expect(t.artist, isNull);
      final hex = (Uint8List b) => b.map((x) => x.toRadixString(16)).join(',');
      expect(hex(out).contains(hex(apic)), isTrue, reason: 'cover frame copied unchanged');
      expect(out.length, old.length, reason: 'fits in the existing padding');
    });
  }

  test('files without a tag get one; the audio after the tag is untouched', () async {
    final dir = await Directory.systemTemp.createTemp('tagw_');
    addTearDown(() => dir.delete(recursive: true));
    final audio = List.generate(5000, (i) => (i * 7) & 0xFF);
    final f = File('${dir.path}${Platform.pathSeparator}a.mp3')..writeAsBytesSync(audio);

    expect(await writeMp3Tags(f.path, title: 'Ünïcode Tïtle', artist: 'Astor', album: 'Perfect Tango'), isTrue);
    final bytes = f.readAsBytesSync();
    final size = ((bytes[6] << 21) | (bytes[7] << 14) | (bytes[8] << 7) | bytes[9]) + 10;
    expect(bytes.sublist(size), audio);
    final t = await readTags(f.path);
    expect((t.title, t.artist, t.album), ('Ünïcode Tïtle', 'Astor', 'Perfect Tango'));
    expect(File('${f.path}.relabel.tmp').existsSync(), isFalse);

    expect(await writeMp3Tags(f.path, title: 'Second'), isTrue);
    final t2 = await readTags(f.path);
    expect((t2.title, t2.artist, t2.album), ('Second', 'Astor', 'Perfect Tango'));
  });

  test('non-MP3 files and unsafe tags are left alone', () async {
    expect(await writeMp3Tags('x.flac', title: 'T'), isFalse);
    final v22 = Uint8List.fromList([0x49, 0x44, 0x33, 2, 0, 0, 0, 0, 0, 0]);
    expect(buildId3Tag(v22, title: 'T'), isNull);
    final unsync = Uint8List.fromList([0x49, 0x44, 0x33, 3, 0, 0x80, 0, 0, 0, 0]);
    expect(buildId3Tag(unsync, title: 'T'), isNull);
  });
}
