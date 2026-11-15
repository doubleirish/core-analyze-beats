import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shared_core/services/bpm_analyzer.dart';
import 'package:shared_core/services/spectrum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glint_audio_pure/glint_audio_pure.dart';

Float64List sine(double hz, int sr, double sec, {double amp = 0.5}) {
  final x = Float64List((sr * sec).round());
  for (var i = 0; i < x.length; i++) {
    x[i] = amp * math.sin(2 * math.pi * hz * i / sr);
  }
  return x;
}

int argmax(Float64List v) {
  var b = 0;
  for (var i = 1; i < v.length; i++) {
    if (v[i] > v[b]) b = i;
  }
  return b;
}

void main() {
  const sr = 44100;

  test('sine peaks in the matching log-spaced band', () {
    final a = SpectrumAnalyzer(sine(1000, sr, 2), sr);
    final b = a.bandsAt(1.0, 64);
    final expected = (64 * math.log(1000 / 40) / math.log(16000 / 40)).floor();
    expect(argmax(b), closeTo(expected, 1));
    expect(b[argmax(b)], greaterThan(0.8));
    expect(b[0], lessThan(0.2));
    expect(b[63], lessThan(0.2));
  });

  test('higher tone lands in a higher band; silence is zero', () {
    final lo = SpectrumAnalyzer(sine(200, sr, 1), sr).bandsAt(0.5, 48);
    final hi = SpectrumAnalyzer(sine(5000, sr, 1), sr).bandsAt(0.5, 48);
    expect(argmax(hi), greaterThan(argmax(lo)));
    final silent = SpectrumAnalyzer(Float64List(sr), sr).bandsAt(0.5, 48);
    expect(silent.every((v) => v == 0), isTrue);
  });

  test('works at the song edges and with different band counts', () {
    final a = SpectrumAnalyzer(sine(440, sr, 1), sr);
    expect(a.bandsAt(0, 16).length, 16);
    expect(a.bandsAt(5, 96).length, 96);
  });

  test('decoded mp3 keeps a usable scale', () {
    final mp3 = mp3EncodeMono(sine(1000, sr, 3), sampleRate: sr, bitrate: 128);
    final d = decodeMono(Uint8List.fromList(mp3));
    final b = SpectrumAnalyzer(d.mono, d.sampleRate).bandsAt(1.5, 64);
    expect(b[argmax(b)], greaterThan(0.6));
  });
}
