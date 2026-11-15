import 'dart:math' as math;
import 'dart:typed_data';

/// Integrated loudness (LUFS, ITU-R BS.1770 style) of mono samples in -1..1:
/// K-weighting, 400 ms blocks with 75 % overlap, the -70 LUFS absolute gate
/// and the -10 LU relative gate. Null for silence or less than one block.
double? integratedLoudness(Float64List mono, int sampleRate) {
  if (sampleRate <= 0) return null;
  final block = (0.4 * sampleRate).round();
  final step = (0.1 * sampleRate).round();
  if (block <= 0 || step <= 0 || mono.length < block) return null;

  // K-weighting: a high shelf, then a high pass (coefficients for any rate).
  final fs = sampleRate.toDouble();
  var k = math.tan(math.pi * 1681.974450955533 / fs);
  const q1 = 0.7071752369554196;
  final vh = math.pow(10, 3.999843853973347 / 20).toDouble();
  final vb = math.pow(vh, 0.4996667741545416).toDouble();
  var a0 = 1 + k / q1 + k * k;
  final sb0 = (vh + vb * k / q1 + k * k) / a0,
      sb1 = 2 * (k * k - vh) / a0,
      sb2 = (vh - vb * k / q1 + k * k) / a0,
      sa1 = 2 * (k * k - 1) / a0,
      sa2 = (1 - k / q1 + k * k) / a0;
  k = math.tan(math.pi * 38.13547087602444 / fs);
  const q2 = 0.5003270373238773;
  a0 = 1 + k / q2 + k * k;
  final ha1 = 2 * (k * k - 1) / a0, ha2 = (1 - k / q2 + k * k) / a0;

  // Squared K-weighted signal summed per 100 ms step.
  final steps = mono.length ~/ step;
  final energy = Float64List(steps);
  var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0; // shelf state
  var u1 = 0.0, u2 = 0.0, w1 = 0.0, w2 = 0.0; // high-pass state
  for (var s = 0; s < steps; s++) {
    var sum = 0.0;
    final end = (s + 1) * step;
    for (var i = s * step; i < end; i++) {
      final x = mono[i];
      final y = sb0 * x + sb1 * x1 + sb2 * x2 - sa1 * y1 - sa2 * y2;
      x2 = x1;
      x1 = x;
      y2 = y1;
      y1 = y;
      final w = y - 2 * u1 + u2 - ha1 * w1 - ha2 * w2;
      u2 = u1;
      u1 = y;
      w2 = w1;
      w1 = w;
      sum += w * w;
    }
    energy[s] = sum;
  }

  final per = block ~/ step;
  final blocks = <double>[];
  for (var b = 0; b + per <= steps; b++) {
    var z = 0.0;
    for (var j = 0; j < per; j++) {
      z += energy[b + j];
    }
    blocks.add(z / (per * step));
  }
  double lufs(double z) => -0.691 + 10 * math.log(z) / math.ln10;
  final abs = [for (final z in blocks) if (z > 0 && lufs(z) > -70) z];
  if (abs.isEmpty) return null;
  final rel = lufs(abs.reduce((a, b) => a + b) / abs.length) - 10;
  final gated = [for (final z in abs) if (lufs(z) > rel) z];
  if (gated.isEmpty) return null;
  return lufs(gated.reduce((a, b) => a + b) / gated.length);
}

/// Default playback level songs are brought to.
const defaultTargetLufs = -14.0;

/// Volume (0..1) that brings a song measured at [lufs] down to [target];
/// quieter songs play at full volume (never boosted, so nothing clips).
/// [floor] limits how far a very loud song is turned down.
double gainForLoudness(double? lufs, {double target = defaultTargetLufs, double floor = 0.25}) {
  if (lufs == null || !lufs.isFinite) return 1;
  final g = math.pow(10, (target - lufs) / 20).toDouble();
  return g.clamp(floor, 1.0);
}

/// A target that needs no boosting for most of [levels]: the 20th
/// percentile, capped at [defaultTargetLufs] (null when nothing is measured).
double? targetForMix(Iterable<double?> levels) {
  final l = [for (final v in levels) if (v != null && v.isFinite) v]..sort();
  if (l.isEmpty) return null;
  return math.min(defaultTargetLufs, l[(l.length * 0.2).floor().clamp(0, l.length - 1)]);
}
