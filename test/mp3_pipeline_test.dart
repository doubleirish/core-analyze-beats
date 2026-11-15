import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shared_core/services/bpm_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glint_audio_pure/glint_audio_pure.dart';

void main() {
  test('end-to-end: encode mp3 click track, decode, analyze', () async {
    const sr = 44100;
    final pcm = Float64List(sr * 40);
    for (var t = 0.0; t < 40; t += 60 / 128) {
      final s = (t * sr).round();
      for (var i = 0; i < 1500 && s + i < pcm.length; i++) {
        pcm[s + i] += 0.8 * math.sin(i * 0.9) * math.exp(-i / 300);
      }
    }
    final mp3 = mp3EncodeMono(pcm, sampleRate: sr, bitrate: 128);
    final tm = await analyzeMp3Bytes(Uint8List.fromList(mp3));
    expect(tm.durationSec, closeTo(40, 1));
    expect(tm.byAlgo.length, 7);
    for (final e in tm.byAlgo.entries) {
      expect(e.value.segments.first.bpm, closeTo(128, 3), reason: e.key);
    }
    stdout.writeln(
        'segments: ${tm.byAlgo.map((k, v) => MapEntry(k, v.segments.map((s) => s.bpm).toList()))}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
