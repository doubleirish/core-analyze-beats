const baselineId = 'baseline';

/// A user correction for a wrongly detected tempo: exactly one of [scale]
/// (multiplies every segment, e.g. 0.5 / 2) or [bpm] (one constant tempo).
class ManualBpm {
  const ManualBpm({this.scale, this.bpm})
      : assert((scale == null) != (bpm == null));

  final double? scale;
  final double? bpm;

  /// Applies the fix to [m] (whose own duration is used for a constant bpm).
  TempoMap apply(TempoMap m) {
    final List<TempoSegment> segs;
    if (bpm != null) {
      segs = [TempoSegment(0, m.durationSec, bpm!)];
    } else {
      segs = [
        for (final s in m.segments) TempoSegment(s.startSec, s.endSec, s.bpm * scale!)
      ];
    }
    return TempoMap(
        durationSec: m.durationSec,
        segments: segs,
        fileSize: m.fileSize,
        modifiedMs: m.modifiedMs,
        version: m.version);
  }

  Map<String, dynamic> toJson() => {
        if (scale != null) 'scale': scale,
        if (bpm != null) 'bpm': bpm,
      };

  static ManualBpm? fromJson(Object? j) {
    if (j is! Map) return null;
    final scale = (j['scale'] as num?)?.toDouble();
    final bpm = (j['bpm'] as num?)?.toDouble();
    if (bpm != null) return ManualBpm(bpm: bpm);
    if (scale != null) return ManualBpm(scale: scale);
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ManualBpm && other.scale == scale && other.bpm == bpm;

  @override
  int get hashCode => Object.hash(scale, bpm);
}

/// Tempo maps from every algorithm for one file; this is what the .bpm file holds.
class TempoResults {
  TempoResults({
    required this.durationSec,
    required this.byAlgo,
    this.fileSize = 0,
    this.modifiedMs = 0,
    this.manual,
    this.loudness,
  });

  /// Integrated loudness in LUFS (see integratedLoudness); null if unknown.
  final double? loudness;

  final double durationSec;

  /// Raw detected maps; use [mapFor] to get them with [manual] applied.
  final Map<String, TempoMap> byAlgo;
  final int fileSize;
  final int modifiedMs;

  /// User tempo fix applied by [mapFor]; null = trust the detection.
  final ManualBpm? manual;

  /// The detected map, without [manual]. Falls back to the baseline result
  /// (e.g. for old v1 files).
  TempoMap? rawMapFor(String id) => byAlgo[id] ?? byAlgo[baselineId];

  /// The map with the user's [manual] fix applied.
  TempoMap? mapFor(String id) => effectiveMap(id);

  TempoMap? effectiveMap(String algoId) {
    final m = rawMapFor(algoId);
    final fix = manual;
    if (fix == null) return m;
    if (m == null) {
      return fix.bpm == null
          ? null
          : TempoMap(
              durationSec: durationSec,
              segments: [TempoSegment(0, durationSec, fix.bpm!)]);
    }
    return fix.apply(m);
  }

  TempoResults stamped(int size, int modified) => TempoResults(
      durationSec: durationSec,
      byAlgo: byAlgo,
      fileSize: size,
      modifiedMs: modified,
      manual: manual,
      loudness: loudness);

  TempoResults withManual(ManualBpm? fix) => TempoResults(
      durationSec: durationSec,
      byAlgo: byAlgo,
      fileSize: fileSize,
      modifiedMs: modifiedMs,
      manual: fix,
      loudness: loudness);

  Map<String, dynamic> toJson() => {
        'version': 2,
        'duration': durationSec,
        'fileSize': fileSize,
        'modifiedMs': modifiedMs,
        'algorithms': {
          for (final e in byAlgo.entries)
            e.key: {'segments': e.value.segments.map((s) => s.toJson()).toList()}
        },
        if (manual != null) 'manual': manual!.toJson(),
        'loudness': ?loudness,
      };

  factory TempoResults.fromJson(Map<String, dynamic> j) {
    final dur = (j['duration'] as num).toDouble();
    List<TempoSegment> segs(List l) => l
        .map((e) => TempoSegment.fromJson(e as Map<String, dynamic>))
        .toList();
    final by = <String, TempoMap>{};
    if (j['algorithms'] is Map) {
      (j['algorithms'] as Map).forEach((k, v) {
        by[k as String] = TempoMap(
            durationSec: dur, segments: segs((v as Map)['segments'] as List));
      });
    } else {
      // version 1: a single baseline tempo map
      by[baselineId] =
          TempoMap(durationSec: dur, segments: segs(j['segments'] as List));
    }
    return TempoResults(
      durationSec: dur,
      byAlgo: by,
      fileSize: (j['fileSize'] as num?)?.toInt() ?? 0,
      modifiedMs: (j['modifiedMs'] as num?)?.toInt() ?? 0,
      manual: ManualBpm.fromJson(j['manual']),
      loudness: (j['loudness'] as num?)?.toDouble(),
    );
  }
}

class TempoSegment {
  const TempoSegment(this.startSec, this.endSec, this.bpm);

  final double startSec;
  final double endSec;
  final double bpm;

  Map<String, dynamic> toJson() => {'start': startSec, 'end': endSec, 'bpm': bpm};

  factory TempoSegment.fromJson(Map<String, dynamic> j) => TempoSegment(
      (j['start'] as num).toDouble(),
      (j['end'] as num).toDouble(),
      (j['bpm'] as num).toDouble());
}

class TempoMap {
  TempoMap({
    required this.durationSec,
    required this.segments,
    this.fileSize = 0,
    this.modifiedMs = 0,
    this.version = 1,
  });

  final int version;
  final double durationSec;
  final List<TempoSegment> segments;
  final int fileSize;
  final int modifiedMs;

  double? get firstBpm => segments.isEmpty ? null : segments.first.bpm;

  double? get averageBpm {
    if (segments.isEmpty) return null;
    var sum = 0.0, total = 0.0;
    for (final s in segments) {
      final len = s.endSec - s.startSec;
      sum += s.bpm * len;
      total += len;
    }
    return total == 0 ? segments.first.bpm : sum / total;
  }

  /// Duration-weighted median tempo.
  double? get medianBpm {
    if (segments.isEmpty) return null;
    final s = [...segments]..sort((a, b) => a.bpm.compareTo(b.bpm));
    final total = s.fold<double>(0, (a, e) => a + (e.endSec - e.startSec));
    var acc = 0.0;
    for (final e in s) {
      acc += e.endSec - e.startSec;
      if (acc >= total / 2) return e.bpm;
    }
    return s.last.bpm;
  }

  TempoSegment? segmentAt(double sec) {
    if (segments.isEmpty) return null;
    for (final s in segments) {
      if (sec < s.endSec) return s;
    }
    return segments.last;
  }

  /// The segment following the one active at [sec], or null if none.
  TempoSegment? nextSegmentAfter(double sec) {
    final cur = segmentAt(sec);
    if (cur == null) return null;
    final i = segments.indexOf(cur);
    return i + 1 < segments.length ? segments[i + 1] : null;
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'duration': durationSec,
        'fileSize': fileSize,
        'modifiedMs': modifiedMs,
        'segments': segments.map((s) => s.toJson()).toList(),
      };

  factory TempoMap.fromJson(Map<String, dynamic> j) => TempoMap(
        version: (j['version'] as num?)?.toInt() ?? 1,
        durationSec: (j['duration'] as num).toDouble(),
        fileSize: (j['fileSize'] as num?)?.toInt() ?? 0,
        modifiedMs: (j['modifiedMs'] as num?)?.toInt() ?? 0,
        segments: (j['segments'] as List)
            .map((e) => TempoSegment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
