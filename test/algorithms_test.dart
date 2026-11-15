import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shared_core/services/algorithms.dart';
import 'package:shared_core/services/bpm_analyzer.dart';
import 'package:shared_core/services/dsp.dart';
import 'package:flutter_test/flutter_test.dart';

Float64List clicks(List<(double, double)> parts, {int sr = 44100}) {
  final total = parts.fold<double>(0, (a, p) => a + p.$2);
  final out = Float64List((total * sr).round());
  var t0 = 0.0;
  for (final (bpm, dur) in parts) {
    final period = 60 / bpm;
    for (var t = 0.0; t < dur; t += period) {
      final start = ((t0 + t) * sr).round();
      for (var i = 0; i < 1500 && start + i < out.length; i++) {
        out[start + i] += math.sin(i * 0.9) * math.exp(-i / 300);
      }
    }
    t0 += dur;
  }
  return out;
}

void main() {
  test('FFT matches a pure tone bin', () {
    final fft = Fft(256);
    final re = Float64List(256), im = Float64List(256);
    for (var i = 0; i < 256; i++) {
      re[i] = math.cos(2 * math.pi * 10 * i / 256);
    }
    fft.transform(re, im);
    expect(math.sqrt(re[10] * re[10] + im[10] * im[10]), closeTo(128, 1e-6));
    expect(re[11].abs() + im[11].abs(), lessThan(1e-6));
  });

  final constant = clicks([(120, 40)]);
  final changing = clicks([(100, 40), (140, 40)]);
  final ctxConst = AnalysisContext(constant, 44100);
  final ctxChange = AnalysisContext(changing, 44100);

  for (final a in allAlgorithms) {
    test('${a.id}: constant 120 BPM', () {
      final sw = Stopwatch()..start();
      final m = a.analyze(ctxConst);
      // ignore: avoid_print
      print('${a.id} constant: ${m.segments.map((s) => s.bpm).toList()} '
          '${sw.elapsedMilliseconds}ms');
      expect(m.segments, isNotEmpty);
      expect(m.medianBpm, closeTo(120, 3));
    });

    test('${a.id}: 100 to 140 BPM change', () {
      final m = a.analyze(ctxChange);
      // ignore: avoid_print
      print('${a.id} change: ${m.segments.map((s) => '${s.bpm}@${s.startSec.round()}').toList()}');
      expect(m.segments.first.bpm, closeTo(100, 5));
      expect(m.segments.last.bpm, closeTo(140, 6));
    });
  }

  test('analyzeAll returns every algorithm', () {
    final r = analyzeAll(constant, 44100);
    expect(r.byAlgo.keys.toSet(), allAlgorithms.map((a) => a.id).toSet());
  });
}
