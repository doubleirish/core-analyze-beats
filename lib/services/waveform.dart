import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'bpm_analyzer.dart';
import 'dsp.dart';

/// Loudness overview of a song plus its onset envelope (used for beat phase).
class WaveformData {
  WaveformData({
    required this.duration,
    required this.fileSize,
    required this.peaks,
    required this.env,
    required this.envFps,
  });

  final double duration;
  final int fileSize;

  /// Per-bucket peak level 0..255, evenly spaced over [duration].
  final Uint8List peaks;

  /// Onset strength 0..255 at [envFps] frames per second.
  final Uint8List env;
  final double envFps;

  static const _magic = 0x42575631; // "BWV1"

  Uint8List toBytes() {
    final out = ByteData(4 + 8 + 8 + 8 + 4 + 4 + peaks.length + env.length);
    var o = 0;
    out.setUint32(o, _magic);
    o += 4;
    out.setFloat64(o, duration);
    o += 8;
    out.setFloat64(o, fileSize.toDouble());
    o += 8;
    out.setFloat64(o, envFps);
    o += 8;
    out.setUint32(o, peaks.length);
    o += 4;
    out.setUint32(o, env.length);
    o += 4;
    final bytes = out.buffer.asUint8List();
    bytes.setRange(o, o + peaks.length, peaks);
    bytes.setRange(o + peaks.length, o + peaks.length + env.length, env);
    return bytes;
  }

  static WaveformData? fromBytes(Uint8List b) {
    if (b.length < 36) return null;
    final d = ByteData.sublistView(b);
    if (d.getUint32(0) != _magic) return null;
    final duration = d.getFloat64(4);
    final size = d.getFloat64(12).toInt();
    final fps = d.getFloat64(20);
    final np = d.getUint32(28), ne = d.getUint32(32);
    if (b.length != 36 + np + ne) return null;
    return WaveformData(
      duration: duration,
      fileSize: size,
      peaks: Uint8List.fromList(b.sublist(36, 36 + np)),
      env: Uint8List.fromList(b.sublist(36 + np)),
      envFps: fps,
    );
  }

  /// Onset strength 0..1 at [t] seconds.
  double envAt(double t) {
    final i = (t * envFps).round();
    return i < 0 || i >= env.length ? 0 : env[i] / 255;
  }
}

WaveformData computeWaveformFromPcm(Float64List mono, int sampleRate, int fileSize,
    {int buckets = 1000}) {
  final n = mono.length;
  final raw = Float64List(buckets);
  var maxPeak = 1e-9;
  for (var b = 0; b < buckets; b++) {
    final from = n * b ~/ buckets, to = n * (b + 1) ~/ buckets;
    var m = 0.0;
    for (var i = from; i < to; i++) {
      final v = mono[i].abs();
      if (v > m) m = v;
    }
    raw[b] = m;
    if (m > maxPeak) maxPeak = m;
  }
  final peaks = Uint8List(buckets);
  for (var b = 0; b < buckets; b++) {
    peaks[b] = (math.pow(raw[b] / maxPeak, 0.7) * 255).round().clamp(0, 255);
  }
  final ctx = AnalysisContext(mono, sampleRate);
  final flux = ctx.fluxEnv;
  var maxEnv = 1e-9;
  for (final v in flux) {
    if (v > maxEnv) maxEnv = v;
  }
  final env = Uint8List(flux.length);
  for (var i = 0; i < flux.length; i++) {
    env[i] = (flux[i] / maxEnv * 255).round().clamp(0, 255);
  }
  return WaveformData(
      duration: ctx.duration, fileSize: fileSize, peaks: peaks, env: env, envFps: ctx.fps);
}

/// Seconds of near-silence at the start of [w], or 0 when the song starts audibly.
double leadingSilence(WaveformData w, {int threshold = 8}) {
  if (w.peaks.isEmpty || w.duration <= 0) return 0;
  final bucket = w.duration / w.peaks.length;
  var i = 0;
  while (i < w.peaks.length && w.peaks[i] <= threshold) {
    i++;
  }
  if (i >= w.peaks.length) return 0;
  return i * bucket;
}

WaveformData _computeFromMp3(Uint8List bytes) {
  final d = decodeMono(bytes);
  return computeWaveformFromPcm(d.mono, d.sampleRate, bytes.length);
}

Future<WaveformData> computeWaveformInIsolate(Uint8List mp3) =>
    compute(_computeFromMp3, mp3);

WaveformData _computeFromPath(String path) {
  final d = decodeFileMono(path);
  return computeWaveformFromPcm(d.mono, d.sampleRate, File(path).lengthSync());
}

/// Like [computeWaveformInIsolate] but for any supported format.
Future<WaveformData> computeWaveformForFile(String path) => compute(_computeFromPath, path);

/// Persists waveform data as `<song>.mp3.wave` next to the song.
class WaveformStore {
  static File fileFor(String mp3Path) => File('$mp3Path.wave');

  static Future<WaveformData?> load(String mp3Path) async {
    try {
      final f = fileFor(mp3Path);
      if (!await f.exists()) return null;
      final w = WaveformData.fromBytes(await f.readAsBytes());
      if (w == null || w.fileSize != await File(mp3Path).length()) return null;
      return w;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String mp3Path, WaveformData w) async {
    try {
      await fileFor(mp3Path).writeAsBytes(w.toBytes());
    } catch (_) {
      // Read-only folder: the waveform is just recomputed next time.
    }
  }
}

/// Offset (seconds after [start]) of the first beat in a segment, found by
/// sliding a pulse train at [bpm] over the onset envelope.
double beatOffset(WaveformData w, double start, double end, double bpm) {
  final period = 60 / bpm;
  if (end - start < period * 2) return 0;
  final step = 1 / w.envFps;
  var best = 0.0, bestScore = -1.0;
  for (var o = 0.0; o < period; o += step) {
    var score = 0.0;
    for (var t = start + o; t < end; t += period) {
      score += math.max(w.envAt(t), math.max(w.envAt(t - step), w.envAt(t + step)));
    }
    if (score > bestScore) {
      bestScore = score;
      best = o;
    }
  }
  return best;
}
