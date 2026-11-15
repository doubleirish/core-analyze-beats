/// One timed sub-activity inside a song, e.g. "Right leg" or "Surge".
class StepSegment {
  const StepSegment({
    required this.label,
    required this.start,
    required this.end,
    required this.minRpm,
    required this.maxRpm,
    this.icon = '',
    this.lead = false,
    this.cue,
    this.gear,
    this.note,
  });

  /// Trainer's reminder for this sub-activity (set by hand in the mix editor).
  final String? note;

  final String label;

  /// Gears above the base gear; null = not set.
  final int? gear;

  /// Icon key understood by `iconForKey`.
  final String icon;

  /// Seconds from the start of the song.
  final double start;
  final double end;
  final double minRpm;
  final double maxRpm;

  /// Steady lead-in / lead-out at the edges of a song.
  final bool lead;

  /// Short instruction shown with the segment, e.g. "Add resistance".
  final String? cue;

  double get length => end - start;

  Map<String, dynamic> toJson() => {
        'label': label,
        'icon': icon,
        'start': start,
        'end': end,
        'minRpm': minRpm,
        'maxRpm': maxRpm,
        if (lead) 'lead': true,
        if (cue != null) 'cue': cue,
        if (gear != null) 'gear': gear,
        if (note != null && note!.isNotEmpty) 'note': note,
      };

  factory StepSegment.fromJson(Map<String, dynamic> j) => StepSegment(
        label: j['label'] as String? ?? '',
        icon: j['icon'] as String? ?? '',
        start: (j['start'] as num?)?.toDouble() ?? 0,
        end: (j['end'] as num?)?.toDouble() ?? 0,
        minRpm: (j['minRpm'] as num?)?.toDouble() ?? 0,
        maxRpm: (j['maxRpm'] as num?)?.toDouble() ?? 0,
        lead: j['lead'] == true,
        cue: j['cue'] as String?,
        gear: (j['gear'] as num?)?.toInt(),
        note: j['note'] as String?,
      );
}

/// What to do during one song of a program part: the activity, its overall
/// RPM range and the sub-activities that fill the song.
class StepPlan {
  const StepPlan({
    required this.activity,
    required this.icon,
    required this.minRpm,
    required this.maxRpm,
    this.segments = const [],
    this.baseGear,
    this.notes,
    this.timedNotes = const [],
  });

  /// Trainer notes pinned to a moment of the song.
  final List<TimedNote> timedNotes;

  /// The note to show at [sec]: the latest one that started within [hold] seconds.
  TimedNote? timedNoteAt(double sec, {double hold = 10}) => activeTimedNote(timedNotes, sec, hold: hold);

  /// The instructor's coaching notes for the whole activity.
  final String? notes;

  /// This part's own base gear; null = use the rider's.
  final int? baseGear;
  final String activity;
  final String icon;
  final double minRpm;
  final double maxRpm;
  final List<StepSegment> segments;

  /// The sub-activity at [sec], clamped to the first/last; null with no segments.
  StepSegment? segmentAt(double sec) {
    if (segments.isEmpty) return null;
    for (final s in segments) {
      if (sec < s.end) return s;
    }
    return segments.last;
  }

  /// The segment after the one at [sec], or null at the end.
  StepSegment? segmentAfter(double sec) {
    final cur = segmentAt(sec);
    if (cur == null) return null;
    final i = segments.indexOf(cur);
    return i + 1 < segments.length ? segments[i + 1] : null;
  }

  /// First segment that is not a lead-in (the real work), else the first one.
  StepSegment? get firstWork =>
      segments.where((s) => !s.lead).firstOrNull ?? segments.firstOrNull;

  Map<String, dynamic> toJson() => {
        'activity': activity,
        'icon': icon,
        'minRpm': minRpm,
        'maxRpm': maxRpm,
        'segments': [for (final s in segments) s.toJson()],
        if (baseGear != null) 'baseGear': baseGear,
        if (notes != null && notes!.isNotEmpty) 'notes': notes,
        if (timedNotes.isNotEmpty) 'timedNotes': [for (final n in timedNotes) n.toJson()],
      };

  factory StepPlan.fromJson(Map<String, dynamic> j) => StepPlan(
        activity: j['activity'] as String? ?? '',
        icon: j['icon'] as String? ?? '',
        minRpm: (j['minRpm'] as num?)?.toDouble() ?? 0,
        maxRpm: (j['maxRpm'] as num?)?.toDouble() ?? 0,
        segments: [
          for (final s in (j['segments'] as List? ?? const []))
            StepSegment.fromJson((s as Map).cast<String, dynamic>())
        ],
        baseGear: (j['baseGear'] as num?)?.toInt(),
        notes: j['notes'] as String?,
        timedNotes: [
          for (final n in (j['timedNotes'] as List? ?? const []))
            TimedNote.fromJson((n as Map).cast<String, dynamic>())
        ],
      );
}

/// A trainer note pinned to [at] seconds into a song.
class TimedNote {
  const TimedNote(this.at, this.text);
  final double at;
  final String text;

  TimedNote copyWith({double? at, String? text}) => TimedNote(at ?? this.at, text ?? this.text);

  Map<String, dynamic> toJson() => {'at': at, 'text': text};

  factory TimedNote.fromJson(Map<String, dynamic> j) =>
      TimedNote((j['at'] as num?)?.toDouble() ?? 0, j['text'] as String? ?? '');

  @override
  bool operator ==(Object other) => other is TimedNote && other.at == at && other.text == text;

  @override
  int get hashCode => Object.hash(at, text);
}

/// The note of [notes] (sorted or not) that started at most [hold] seconds
/// before [sec], preferring the latest; null when none is showing.
TimedNote? activeTimedNote(List<TimedNote> notes, double sec, {double hold = 10}) {
  TimedNote? best;
  for (final n in notes) {
    if (n.at <= sec && sec < n.at + hold && (best == null || n.at >= best.at)) best = n;
  }
  return best;
}

/// A main activity coming up later in the mix.
class UpcomingStep {
  const UpcomingStep(this.activity, this.plan, this.index);
  final String activity;
  final StepPlan? plan;

  /// Queue index of the first song of this activity.
  final int index;
}

/// One activity across the whole mix: consecutive songs of the same activity
/// merged, positioned on the mix's clock (seconds from the start of the queue).
class MixBlock {
  const MixBlock(this.activity, this.plan, this.start, this.seconds, this.firstSong, this.songs);
  final String activity;
  final StepPlan? plan;
  final double start;
  final double seconds;
  final int firstSong;
  final int songs;
  double get end => start + seconds;
}

String rpmText(double lo, double hi) =>
    lo.round() == hi.round() ? '${lo.round()} RPM' : '${lo.round()}–${hi.round()} RPM';
