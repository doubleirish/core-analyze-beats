import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';

/// Computes log-spaced frequency band levels (0..1) at a playback position.
class SpectrumAnalyzer {
  SpectrumAnalyzer(this.mono, this.sampleRate) : _fft = Fft(size) {
    _window = Float64List(size);
    for (var i = 0; i < size; i++) {
      _window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (size - 1));
    }
  }

  static const size = 2048;
  static const minHz = 40.0;
  static const maxHz = 16000.0;
  static const floorDb = -70.0;
  static const ceilDb = -10.0;

  final Float64List mono;
  final int sampleRate;
  final Fft _fft;
  late final Float64List _window;
  final _re = Float64List(size);
  final _im = Float64List(size);

  double get durationSec => mono.length / sampleRate;

  Float64List bandsAt(double posSec, int bandCount) {
    final out = Float64List(bandCount);
    final start = (posSec * sampleRate).round() - size ~/ 2;
    var energy = 0.0;
    for (var i = 0; i < size; i++) {
      final j = start + i;
      final v = j >= 0 && j < mono.length ? mono[j] : 0.0;
      _re[i] = v * _window[i];
      _im[i] = 0;
      energy += v * v;
    }
    if (energy < 1e-12) return out;
    _fft.transform(_re, _im);

    final hiHz = math.min(maxHz, sampleRate / 2.0);
    final ratio = hiHz / minHz;
    final binHz = sampleRate / size;
    for (var b = 0; b < bandCount; b++) {
      final f0 = minHz * math.pow(ratio, b / bandCount);
      final f1 = minHz * math.pow(ratio, (b + 1) / bandCount);
      final k0 = (f0 / binHz).floor();
      final k1 = math.max(k0, (f1 / binHz).ceil() - 1);
      var peak = 0.0;
      for (var k = math.max(1, k0); k <= math.min(size ~/ 2 - 1, k1); k++) {
        final m = math.sqrt(_re[k] * _re[k] + _im[k] * _im[k]);
        if (m > peak) peak = m;
      }
      // 2 / sum(window) normalises a full-scale sine to magnitude ~1
      final db = 20 * math.log(peak * 2 / (size * 0.5) + 1e-9) / math.ln10;
      out[b] = ((db - floorDb) / (ceilDb - floorDb)).clamp(0.0, 1.0);
    }
    return out;
  }
}
