import 'package:shared_core/shared_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final raw = TempoResults(durationSec: 200, byAlgo: {
    baselineId: TempoMap(durationSec: 200, segments: const [
      TempoSegment(0, 100, 70),
      TempoSegment(100, 200, 72),
    ]),
    'flux': TempoMap(durationSec: 200, segments: const [TempoSegment(0, 200, 140)]),
  });

  test('scale multiplies every segment; rawMapFor stays as detected', () {
    final r = raw.withManual(const ManualBpm(scale: 2));
    expect(r.mapFor(baselineId)!.segments.map((s) => s.bpm), [140, 144]);
    expect(r.effectiveMap('flux')!.firstBpm, 280);
    expect(r.mapFor('missing')!.firstBpm, 140, reason: 'falls back to baseline');
    expect(r.rawMapFor(baselineId)!.segments.map((s) => s.bpm), [70, 72]);
  });

  test('bpm replaces the map with one constant segment', () {
    final m = raw.withManual(const ManualBpm(bpm: 128)).mapFor('flux')!;
    expect(m.segments, hasLength(1));
    expect(m.segments.single.startSec, 0);
    expect(m.segments.single.endSec, 200);
    expect(m.medianBpm, 128);
  });

  test('manual survives json round-trip and stamped', () {
    final r = TempoResults.fromJson(
        raw.withManual(const ManualBpm(scale: 0.5)).stamped(10, 20).toJson());
    expect(r.manual, const ManualBpm(scale: 0.5));
    expect(r.fileSize, 10);
    expect(r.mapFor(baselineId)!.firstBpm, 35);
    final b = TempoResults.fromJson(raw.withManual(const ManualBpm(bpm: 99)).toJson());
    expect(b.manual, const ManualBpm(bpm: 99));
  });

  test('old sidecars without manual load unchanged', () {
    final j = raw.toJson();
    expect(j.containsKey('manual'), isFalse);
    final r = TempoResults.fromJson(j);
    expect(r.manual, isNull);
    expect(r.mapFor(baselineId)!.segments.map((s) => s.bpm), [70, 72]);
    final v1 = TempoResults.fromJson({
      'duration': 10,
      'segments': [
        {'start': 0, 'end': 10, 'bpm': 120}
      ],
    });
    expect(v1.manual, isNull);
    expect(v1.mapFor('flux')!.firstBpm, 120);
  });
}
