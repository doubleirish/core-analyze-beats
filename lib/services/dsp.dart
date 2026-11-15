import 'dart:math' as math;
import 'dart:typed_data';

import '../models/tempo.dart';

const hopSize = 512;
const minBpm = 70.0;
const maxBpm = 180.0;

/// Estimates one tempo from env[start, end), or null when there is no pulse.
typedef BpmEstimator = double? Function(
    Float64List env, int start, int end, double fps);

/// Radix-2 complex FFT with precomputed tables.
class Fft {
  Fft(this.n)
      : _cos = Float64List(n ~/ 2),
        _sin = Float64List(n ~/ 2),
        _rev = Int32List(n) {
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = math.cos(2 * math.pi * i / n);
      _sin[i] = -math.sin(2 * math.pi * i / n);
    }
    final bits = (math.log(n) / math.ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0;
      for (var b = 0; b < bits; b++) {
        if (i & (1 << b) != 0) r |= 1 << (bits - 1 - b);
      }
      _rev[i] = r;
    }
  }

  final int n;
  final Float64List _cos, _sin;
  final Int32List _rev;

  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i];
        re[i] = re[j];
        re[j] = tr;
        final ti = im[i];
        im[i] = im[j];
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1;
      final step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = _sin[k * step];
          final a = start + k, b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }
}

/// Decoded audio plus lazily computed, shared onset envelopes.
class AnalysisContext {
  AnalysisContext(this.mono, this.sampleRate);

  final Float64List mono;
  final int sampleRate;

  double get duration => mono.length / sampleRate;
  double get fps => sampleRate / hopSize;

  late final Float64List energyEnv = _energyEnvelope(mono);
  late final ({Float64List full, Float64List low}) _flux = _spectralFlux();
  Float64List get fluxEnv => _flux.full;

  /// Spectral flux restricted to bins below 200 Hz (kick drum).
  Float64List get lowFluxEnv => _flux.low;

  ({Float64List full, Float64List low}) _spectralFlux() {
    const n = 2048;
    final frames = mono.length ~/ hopSize;
    final full = Float64List(frames), low = Float64List(frames);
    if (frames < 2) return (full: full, low: low);
    final fft = Fft(n);
    final win = Float64List(n);
    for (var i = 0; i < n; i++) {
      win[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    }
    final re = Float64List(n), im = Float64List(n);
    final prev = Float64List(n ~/ 2);
    final lowBins = math.max(2, (200 / (sampleRate / n)).ceil());
    for (var f = 0; f < frames; f++) {
      final s0 = f * hopSize + hopSize ~/ 2 - n ~/ 2;
      for (var i = 0; i < n; i++) {
        final k = s0 + i;
        re[i] = k >= 0 && k < mono.length ? mono[k] * win[i] : 0;
        im[i] = 0;
      }
      fft.transform(re, im);
      var sum = 0.0, lowSum = 0.0;
      for (var k = 1; k < n ~/ 2; k++) {
        final m = math.log(1 + 10 * math.sqrt(re[k] * re[k] + im[k] * im[k]));
        final d = m - prev[k];
        prev[k] = m;
        if (f > 0 && d > 0) {
          sum += d;
          if (k <= lowBins) lowSum += d;
        }
      }
      full[f] = sum;
      low[f] = lowSum;
    }
    return (full: full, low: low);
  }
}

Float64List _energyEnvelope(Float64List x) {
  final frames = x.length ~/ hopSize;
  final energy = Float64List(frames);
  for (var f = 0; f < frames; f++) {
    var e = 0.0;
    var prev = f * hopSize > 0 ? x[f * hopSize - 1] : 0.0;
    for (var i = f * hopSize; i < (f + 1) * hopSize; i++) {
      final d = x[i] - prev; // first difference emphasises transients
      e += d * d;
      prev = x[i];
    }
    energy[f] = math.log(1 + 1000 * e / hopSize);
  }
  final env = Float64List(frames);
  for (var f = 1; f < frames; f++) {
    final d = energy[f] - energy[f - 1];
    env[f] = d > 0 ? d : 0;
  }
  return env;
}

/// Mild log-prior around 120 BPM resolving half/double-time ambiguity.
double tempoPrior(double bpm) =>
    math.exp(-0.5 * math.pow(math.log(bpm / 120) / 0.6, 2));

/// Mean-removed copy of env[start, end), or null if it is flat.
Float64List? centeredWindow(Float64List env, int start, int end) {
  final len = end - start;
  var mean = 0.0;
  for (var i = start; i < end; i++) {
    mean += env[i];
  }
  mean /= len;
  final seg = Float64List(len);
  var energy = 0.0;
  for (var i = 0; i < len; i++) {
    seg[i] = env[start + i] - mean;
    energy += seg[i] * seg[i];
  }
  return energy < 1e-9 ? null : seg;
}

/// Windowed estimation, smoothing and merging into a tempo map.
TempoMap buildTempoMap(Float64List env, double fps, double duration,
    BpmEstimator estimate,
    {double windowSec = 12, double hopSec = 3, double mergeTolerance = 0.03}) {
  final winLen = (windowSec * fps).round();
  final winHop = math.max(1, (hopSec * fps).round());
  final centers = <double>[];
  final bpms = <double>[];

  if (env.length >= winLen ~/ 2 && env.isNotEmpty) {
    final effWin = math.min(winLen, env.length);
    var start = 0;
    while (true) {
      final end = math.min(start + effWin, env.length);
      final b = estimate(env, start, end, fps);
      if (b != null && b.isFinite) {
        centers.add((start + end) / 2 / fps);
        bpms.add(b);
      }
      if (end >= env.length) break;
      start += winHop;
    }
  }

  if (bpms.isEmpty) {
    return TempoMap(durationSec: duration, segments: const []);
  }

  // Median-of-3 smoothing removes single-window glitches.
  final sm = List<double>.from(bpms);
  for (var i = 1; i < bpms.length - 1; i++) {
    final t = [bpms[i - 1], bpms[i], bpms[i + 1]]..sort();
    sm[i] = t[1];
  }

  final segs = <TempoSegment>[];
  var gStart = 0;
  for (var i = 1; i <= sm.length; i++) {
    final ref = _mean(sm, gStart, i);
    if (i == sm.length || (sm[i] - ref).abs() / ref > mergeTolerance) {
      final s = gStart == 0 ? 0.0 : (centers[gStart - 1] + centers[gStart]) / 2;
      final e = i == sm.length ? duration : (centers[i - 1] + centers[i]) / 2;
      segs.add(TempoSegment(s, e, double.parse(ref.toStringAsFixed(1))));
      gStart = i;
    }
  }
  return TempoMap(durationSec: duration, segments: segs);
}

double _mean(List<double> v, int a, int b) {
  var s = 0.0;
  for (var i = a; i < b; i++) {
    s += v[i];
  }
  return s / (b - a);
}
