import 'dart:math' as math;
import 'dart:typed_data';

import '../models/tempo.dart';
import 'dsp.dart';

abstract class TempoAlgorithm {
  String get id;
  String get name;
  String get short;
  String get description;
  TempoMap analyze(AnalysisContext ctx);
}

class _Algo extends TempoAlgorithm {
  _Algo(this.id, this.name, this.short, this.description, this._env, this._est);

  @override
  final String id, name, short, description;
  final Float64List Function(AnalysisContext) _env;
  final BpmEstimator _est;

  @override
  TempoMap analyze(AnalysisContext ctx) =>
      buildTempoMap(_env(ctx), ctx.fps, ctx.duration, _est);
}

final List<TempoAlgorithm> allAlgorithms = [
  _Algo(baselineId, 'Baseline', 'Base',
      'Energy-difference onsets + autocorrelation', (c) => c.energyEnv, estimateAutocorr),
  _Algo('flux', 'Spectral flux', 'Flux',
      'FFT log-spectral flux + autocorrelation', (c) => c.fluxEnv, estimateAutocorr),
  _Algo('tempogram', 'Fourier tempogram', 'Tempo',
      'Spectral flux, DFT of the onset curve per window', (c) => c.fluxEnv, estimateTempogram),
  _Algo('comb', 'Comb filter', 'Comb',
      'Spectral flux, pulse-train comb bank (best phase)', (c) => c.fluxEnv, estimateComb),
  _Algo('ioi', 'IOI histogram', 'IOI',
      'Peak-picked onsets, inter-onset interval histogram', (c) => c.fluxEnv, estimateIoi),
  _Algo('dp', 'DP beat tracker', 'DP',
      'Ellis dynamic-programming beat tracking, tempo from beat spacing', (c) => c.fluxEnv, estimateDp),
  _Algo('lowband', 'Low band (kick)', 'Low',
      'Spectral flux below 200 Hz + autocorrelation', (c) => c.lowFluxEnv, estimateAutocorr),
];

TempoAlgorithm? algorithmById(String id) {
  for (final a in allAlgorithms) {
    if (a.id == id) return a;
  }
  return null;
}

double _refine(double lag, double a, double b, double c) {
  final den = a - 2 * b + c;
  return den == 0 ? lag : lag + 0.5 * (a - c) / den;
}

double? estimateAutocorr(Float64List env, int start, int end, double fps) {
  final seg = centeredWindow(env, start, end);
  if (seg == null) return null;
  final len = seg.length;

  final minLag = (fps * 60 / maxBpm).floor();
  final maxLag = math.min((fps * 60 / minBpm).ceil(), len - 1);
  if (maxLag <= minLag + 2) return null;

  final ac = Float64List(2 * maxLag + 3);
  for (var lag = minLag - 1; lag <= 2 * maxLag + 1 && lag < len; lag++) {
    var s = 0.0;
    for (var i = lag; i < len; i++) {
      s += seg[i] * seg[i - lag];
    }
    ac[lag] = s / (len - lag); // unbiased
  }

  var bestLag = -1;
  var bestScore = double.negativeInfinity;
  for (var lag = minLag; lag <= maxLag; lag++) {
    var score = ac[lag];
    if (lag * 2 < len) score += 0.5 * ac[lag * 2];
    score *= tempoPrior(60 * fps / lag);
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }
  if (bestLag < 0 || bestScore <= 0) return null;

  var lagF = bestLag.toDouble();
  if (bestLag > minLag && bestLag < maxLag) {
    lagF = _refine(lagF, ac[bestLag - 1], ac[bestLag], ac[bestLag + 1]);
  }
  return 60 * fps / lagF;
}

const _gridStep = 0.5;
const _gridMax = 2 * maxBpm;

double? estimateTempogram(Float64List env, int start, int end, double fps) {
  final seg = centeredWindow(env, start, end);
  if (seg == null) return null;
  final len = seg.length;
  for (var i = 0; i < len; i++) {
    seg[i] *= 0.5 - 0.5 * math.cos(2 * math.pi * i / (len - 1));
  }
  final count = ((_gridMax - minBpm) / _gridStep).floor() + 1;
  final mag = Float64List(count);
  for (var g = 0; g < count; g++) {
    final w = 2 * math.pi * (minBpm + g * _gridStep) / 60 / fps;
    final cw = math.cos(w), sw = math.sin(w);
    var c = 1.0, s = 0.0, re = 0.0, im = 0.0;
    for (var i = 0; i < len; i++) {
      re += seg[i] * c;
      im += seg[i] * s;
      final nc = c * cw - s * sw;
      s = c * sw + s * cw;
      c = nc;
    }
    mag[g] = math.sqrt(re * re + im * im);
  }
  final top = ((maxBpm - minBpm) / _gridStep).floor();
  var best = -1;
  var bestScore = 0.0;
  for (var g = 1; g < top; g++) {
    final bpm = minBpm + g * _gridStep;
    final dbl = ((2 * bpm - minBpm) / _gridStep).round();
    final score = (mag[g] + 0.5 * mag[dbl]) * tempoPrior(bpm);
    if (score > bestScore) {
      bestScore = score;
      best = g;
    }
  }
  if (best < 0) return null;
  final off = _refine(0, mag[best - 1], mag[best], mag[best + 1]);
  return minBpm + (best + off.clamp(-1.0, 1.0)) * _gridStep;
}

double? estimateComb(Float64List env, int start, int end, double fps) {
  final seg = centeredWindow(env, start, end);
  if (seg == null) return null;
  final len = seg.length;
  double at(double p) {
    final i = p.floor();
    if (i < 0 || i + 1 >= len) return 0;
    final f = p - i;
    return seg[i] * (1 - f) + seg[i + 1] * f;
  }

  var best = 0.0;
  var bestBpm = -1.0;
  for (var bpm = minBpm; bpm <= maxBpm; bpm += _gridStep) {
    final period = 60 * fps / bpm;
    var top = 0.0;
    for (var phase = 0.0; phase < period; phase += 0.5) {
      var sum = 0.0;
      var n = 0;
      for (var p = phase; p < len - 1; p += period) {
        sum += at(p);
        n++;
      }
      if (n >= 3) top = math.max(top, sum / n);
    }
    final score = top * tempoPrior(bpm);
    if (score > best) {
      best = score;
      bestBpm = bpm;
    }
  }
  return bestBpm < 0 ? null : bestBpm;
}

double? estimateIoi(Float64List env, int start, int end, double fps) {
  final seg = centeredWindow(env, start, end);
  if (seg == null) return null;
  final len = seg.length;
  var sd = 0.0;
  for (final v in seg) {
    sd += v * v;
  }
  final thr = 0.5 * math.sqrt(sd / len);
  final minGap = (0.1 * fps).round();

  final pos = <int>[];
  final str = <double>[];
  for (var i = 1; i < len - 1; i++) {
    if (seg[i] > thr && seg[i] > seg[i - 1] && seg[i] >= seg[i + 1]) {
      if (pos.isNotEmpty && i - pos.last < minGap) {
        if (seg[i] > str.last) {
          pos[pos.length - 1] = i;
          str[str.length - 1] = seg[i];
        }
      } else {
        pos.add(i);
        str.add(seg[i]);
      }
    }
  }
  if (pos.length < 4) return null;

  final bins = ((maxBpm - minBpm) / _gridStep).floor() + 1;
  final hist = Float64List(bins);
  for (var i = 0; i < pos.length; i++) {
    for (var j = i + 1; j < pos.length && j <= i + 4; j++) {
      final d = (pos[j] - pos[i]) / fps;
      var bpm = 60 / d;
      while (bpm >= maxBpm) {
        bpm /= 2;
      }
      while (bpm < minBpm) {
        bpm *= 2;
      }
      if (bpm >= maxBpm) continue;
      final w = math.min(str[i], str[j]);
      final center = (bpm - minBpm) / _gridStep;
      for (var b = center.floor() - 6; b <= center.ceil() + 6; b++) {
        if (b < 0 || b >= bins) continue;
        final dist = (b - center) * _gridStep;
        hist[b] += w * math.exp(-0.5 * dist * dist / (1.5 * 1.5));
      }
    }
  }
  var best = -1;
  var bestScore = 0.0;
  for (var b = 0; b < bins; b++) {
    final score = hist[b] * tempoPrior(minBpm + b * _gridStep);
    if (score > bestScore) {
      bestScore = score;
      best = b;
    }
  }
  return best < 0 ? null : minBpm + best * _gridStep;
}

double? estimateDp(Float64List env, int start, int end, double fps) {
  final init = estimateAutocorr(env, start, end, fps);
  if (init == null) return null;
  final tau = 60 * fps / init;

  final len = end - start;
  var mean = 0.0;
  for (var i = start; i < end; i++) {
    mean += env[i];
  }
  mean /= len;
  var sd = 0.0;
  for (var i = start; i < end; i++) {
    sd += (env[i] - mean) * (env[i] - mean);
  }
  sd = math.sqrt(sd / len);
  if (sd < 1e-9) return null;
  final o = Float64List(len);
  for (var i = 0; i < len; i++) {
    o[i] = env[start + i] / sd;
  }

  const alpha = 100.0;
  final score = Float64List(len);
  final back = Int32List(len)..fillRange(0, len, -1);
  final lo = (tau / 2).round(), hi = (tau * 2).round();
  for (var t = 0; t < len; t++) {
    var bestPrev = -1;
    var bestVal = 0.0; // starting a new beat chain costs nothing
    for (var p = t - hi; p <= t - lo; p++) {
      if (p < 0) continue;
      final l = math.log((t - p) / tau);
      final v = score[p] - alpha * l * l;
      if (bestPrev < 0 || v > bestVal) {
        bestVal = v;
        bestPrev = p;
      }
    }
    if (bestPrev >= 0 && bestVal > 0) {
      score[t] = o[t] + bestVal;
      back[t] = bestPrev;
    } else {
      score[t] = o[t];
    }
  }

  var last = -1;
  var top = double.negativeInfinity;
  for (var t = math.max(0, len - hi); t < len; t++) {
    if (score[t] > top) {
      top = score[t];
      last = t;
    }
  }
  if (last < 0) return null;
  final beats = <int>[];
  for (var t = last; t >= 0; t = back[t]) {
    beats.add(t);
    if (back[t] < 0) break;
  }
  if (beats.length < 4) return null;
  final meanInterval = (beats.first - beats.last) / (beats.length - 1);
  return 60 * fps / meanInterval;
}
