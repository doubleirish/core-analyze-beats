import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shared_core/services/metronome.dart';
import 'package:shared_core/services/player_engine.dart';
import 'package:shared_core/services/waveform.dart';
import 'package:flutter_test/flutter_test.dart';

Float64List clickTrack(int sr, double seconds, double bpm, double first) {
  final x = Float64List((sr * seconds).round());
  final period = 60 / bpm;
  for (var t = first; t < seconds - 0.05; t += period) {
    final s = (t * sr).round();
    for (var i = 0; i < 300; i++) {
      x[s + i] = math.sin(2 * math.pi * 1500 * i / sr) * math.exp(-i / 60);
    }
  }
  return x;
}

void main() {
  test('waveform file round trips and rejects garbage', () {
    final w = computeWaveformFromPcm(clickTrack(22050, 4, 120, 0.1), 22050, 1234, buckets: 50);
    expect(w.peaks.length, 50);
    final back = WaveformData.fromBytes(w.toBytes())!;
    expect(back.fileSize, 1234);
    expect(back.peaks, w.peaks);
    expect(back.env, w.env);
    expect(back.duration, closeTo(w.duration, 1e-9));
    expect(WaveformData.fromBytes(Uint8List(10)), isNull);
  });

  test('peaks follow loudness', () {
    final x = Float64List(22050 * 2);
    for (var i = 22050; i < x.length; i++) {
      x[i] = math.sin(i * 0.1);
    }
    final w = computeWaveformFromPcm(x, 22050, 1, buckets: 10);
    expect(w.peaks.first, 0);
    expect(w.peaks.last, 255);
  });

  test('beatOffset finds the first beat position', () {
    final w = computeWaveformFromPcm(clickTrack(22050, 20, 120, 0.13), 22050, 1);
    expect(beatOffset(w, 0, 20, 120), closeTo(0.13, 0.04));
    // Segment starting mid-bar: beats still land at the same absolute times.
    final o = beatOffset(w, 5.2, 20, 120);
    expect((5.2 + o - 0.13) % 0.5, anyOf(closeTo(0, 0.04), closeTo(0.5, 0.04)));
  });

  test('beatPhase and flashLevel', () {
    expect(beatPhase(1.0, 0, 0, 120), closeTo(0, 1e-9));
    expect(beatPhase(1.125, 0, 0, 120), closeTo(0.25, 1e-9));
    expect(beatPhase(1.13, 1, 0.13, 120), closeTo(0, 1e-9));
    expect(flashLevel(0), 1);
    expect(flashLevel(0.99), lessThan(0.01));
  });

  test('click wav is a valid RIFF file', () {
    final b = clickWav();
    expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE');
    expect(ByteData.sublistView(b).getUint32(40, Endian.little), b.length - 44);
  });

  test('crossfade gains are equal power', () {
    expect(fadeGains(0), (1.0, 0.0));
    final (a, b) = fadeGains(0.5);
    expect(a * a + b * b, closeTo(1, 1e-9));
    final (c, d) = fadeGains(1);
    expect(c, closeTo(0, 1e-9));
    expect(d, closeTo(1, 1e-9));
  });
}
