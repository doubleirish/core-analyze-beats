import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:glint_audio_pure/glint_audio_pure.dart';

import '../models/tempo.dart';
import 'algorithms.dart';
import 'container_tags.dart';
import 'dsp.dart';
import 'loudness.dart';

/// Decodes the mp3 bytes in a background isolate and runs every algorithm.
Future<TempoResults> analyzeMp3Bytes(Uint8List bytes) =>
    compute(_analyzeBytes, bytes);

TempoResults _analyzeBytes(Uint8List bytes) {
  final d = decodeMono(bytes);
  return analyzeAll(d.mono, d.sampleRate);
}

class MonoPcm {
  MonoPcm(this.mono, this.sampleRate);
  final Float64List mono;
  final int sampleRate;
}

/// Decodes mp3 bytes to mono samples.
MonoPcm decodeMono(Uint8List bytes) {
  final pcm = mp3Decode(bytes);
  final ch = pcm.channels;
  final n = pcm.samples.length ~/ ch;
  final mono = Float64List(n);
  for (var i = 0; i < n; i++) {
    var s = 0.0;
    for (var c = 0; c < ch; c++) {
      s += pcm.samples[i * ch + c];
    }
    mono[i] = s / ch;
  }
  return MonoPcm(mono, pcm.sampleRate);
}

Future<MonoPcm> decodeMonoInIsolate(Uint8List bytes) => compute(decodeMono, bytes);

/// Analyzes any supported file (mp3 natively; m4a/wma through ffmpeg).
Future<TempoResults> analyzeFile(String path) => compute(_analyzePath, path);

/// Decodes [path] and measures only its loudness (LUFS), in an isolate.
Future<double?> measureLoudness(String path) => compute(_loudnessOf, path);

double? _loudnessOf(String path) {
  final d = decodeFileMono(path);
  return integratedLoudness(d.mono, d.sampleRate);
}

TempoResults _analyzePath(String path) {
  final d = decodeFileMono(path);
  return analyzeAll(d.mono, d.sampleRate);
}

Future<MonoPcm> decodeFileInIsolate(String path) => compute(decodeFileMono, path);

/// Decodes a file to mono samples. Only mp3 has a built-in decoder; other
/// formats need an `ffmpeg` executable (PATH, `FFMPEG_PATH`, or next to the app).
MonoPcm decodeFileMono(String path) {
  if (isMp3Path(path)) return decodeMono(File(path).readAsBytesSync());
  final ffmpeg = findFfmpeg();
  if (ffmpeg == null) {
    throw UnsupportedError('Analyzing ${path.split(RegExp(r'[\\/]')).last} needs ffmpeg on PATH');
  }
  final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}'
      'analyze_${DateTime.now().microsecondsSinceEpoch}_${path.hashCode.toRadixString(16)}.wav');
  try {
    final r = Process.runSync(ffmpeg,
        ['-v', 'error', '-nostdin', '-y', '-i', path, '-vn', '-ac', '1', '-acodec', 'pcm_s16le', tmp.path]);
    if (r.exitCode != 0 || !tmp.existsSync()) {
      throw FormatException('ffmpeg could not decode the file: ${r.stderr}');
    }
    final wav = readWavPcm16(tmp.readAsBytesSync());
    return MonoPcm(wavToMonoFloat(wav), wav.sampleRate);
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {}
  }
}

String? _ffmpegPath;
bool _ffmpegSearched = false;

/// Path of an ffmpeg executable, or null when none is available.
String? findFfmpeg() {
  if (_ffmpegSearched) return _ffmpegPath;
  _ffmpegSearched = true;
  final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final dirs = <String>[
    ?Platform.environment['FFMPEG_PATH'],
    File(Platform.resolvedExecutable).parent.path,
    ...(Platform.environment['PATH'] ?? '').split(Platform.isWindows ? ';' : ':'),
  ];
  for (final d in dirs) {
    if (d.isEmpty) continue;
    final f = File('$d${Platform.pathSeparator}$exe');
    if (f.existsSync()) return _ffmpegPath = f.path;
    if (d.toLowerCase().endsWith(exe) && File(d).existsSync()) return _ffmpegPath = d;
  }
  return null;
}

/// Runs every algorithm over the same mono PCM.
TempoResults analyzeAll(Float64List mono, int sampleRate,
    {void Function(String id, int micros)? onTiming}) {
  final ctx = AnalysisContext(mono, sampleRate);
  final by = <String, TempoMap>{};
  for (final a in allAlgorithms) {
    final sw = Stopwatch()..start();
    by[a.id] = a.analyze(ctx);
    onTiming?.call(a.id, sw.elapsedMicroseconds);
  }
  return TempoResults(durationSec: ctx.duration, byAlgo: by, loudness: integratedLoudness(mono, sampleRate));
}

/// Baseline algorithm only.
TempoMap analyzeSamples(Float64List mono, int sampleRate) =>
    algorithmById(baselineId)!.analyze(AnalysisContext(mono, sampleRate));
