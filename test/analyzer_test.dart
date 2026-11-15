import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:shared_core/models/tempo.dart';
import 'package:shared_core/services/bpm_analyzer.dart';
import 'package:shared_core/services/bpm_store.dart';
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
  test('constant tempo', () {
    final m = analyzeSamples(clicks([(120, 40)]), 44100);
    expect(m.segments.length, 1);
    expect(m.segments.first.bpm, closeTo(120, 2));
  });

  test('tempo change is detected', () {
    final m = analyzeSamples(clicks([(100, 40), (140, 40)]), 44100);
    expect(m.segments.length, greaterThanOrEqualTo(2));
    expect(m.segments.first.bpm, closeTo(100, 3));
    expect(m.segments.last.bpm, closeTo(140, 4));
    expect(m.nextSegmentAfter(5)!.bpm, closeTo(140, 4));
  });

  test('sidecar round trip and staleness', () async {
    final dir = Directory.systemTemp.createTempSync('beats');
    final mp3 = File('${dir.path}/a.mp3')..writeAsBytesSync([1, 2, 3]);
    await BpmStore.save(
        mp3.path,
        TempoResults(durationSec: 10, byAlgo: {
          baselineId: TempoMap(durationSec: 10, segments: const [TempoSegment(0, 10, 123.4)]),
          'flux': TempoMap(durationSec: 10, segments: const [TempoSegment(0, 10, 61.7)]),
        }));
    final loaded = (await BpmStore.load(mp3.path))!;
    expect(loaded.byAlgo['flux']!.firstBpm, 61.7);
    expect(loaded.mapFor('missing')!.firstBpm, 123.4); // falls back to baseline
    mp3.writeAsBytesSync([1, 2, 3, 4]);
    expect(await BpmStore.load(mp3.path), isNull);
    dir.deleteSync(recursive: true);
  });

  test('version 1 .bpm files load as baseline', () async {
    final dir = Directory.systemTemp.createTempSync('beats');
    final mp3 = File('${dir.path}/a.mp3')..writeAsBytesSync([1, 2, 3]);
    File('${mp3.path}.bpm').writeAsStringSync(
        '{"version":1,"duration":10,"fileSize":3,"modifiedMs":0,'
        '"segments":[{"start":0,"end":10,"bpm":99.5}]}');
    final r = (await BpmStore.load(mp3.path))!;
    expect(r.byAlgo.keys, [baselineId]);
    expect(r.mapFor('flux')!.firstBpm, 99.5);
    dir.deleteSync(recursive: true);
  });
}
