import '../models/step_plan.dart';

/// What a transition alert does: a spoken heads-up, a countdown beep, or the
/// change itself ("go").
enum AlertKind { voice, beep, go }

/// One alert at [at] seconds into the current song (its plan's time base).
class AlertMark {
  const AlertMark(this.at, this.kind, [this.text]);
  final double at;
  final AlertKind kind;
  final String? text;

  @override
  String toString() => 'AlertMark($at, $kind, $text)';
}

/// The alert types a rider can switch on.
const alertTypes = ['voice', 'beep', 'flash', 'vibrate'];

/// Seconds before a change that the voice heads-up is given.
const alertVoiceLead = 10.0;

/// The go mark for the end of the song sits this far before the very end,
/// since the player hands over to the next song a moment before that.
const alertEndSlack = 0.25;

/// Alerts for the current song: each change of activity inside its [plan]
/// (lead-in/out segments excluded) and, when [nextLabel] is given, the song's
/// end where the next song starts a different activity. Each change gets a
/// voice heads-up [alertVoiceLead] seconds ahead, beeps at 3-2-1 and a go mark.
List<AlertMark> alertMarks(StepPlan? plan, {double? songLength, String? nextLabel}) {
  final changes = <(double, String)>[];
  final segs = plan?.segments ?? const <StepSegment>[];
  for (var i = 1; i < segs.length; i++) {
    final s = segs[i], p = segs[i - 1];
    if (s.lead || s.start <= 0) continue;
    if (s.label == p.label && s.minRpm == p.minRpm && s.maxRpm == p.maxRpm) continue;
    changes.add((s.start, s.label));
  }
  if (nextLabel != null && songLength != null && songLength > 1) {
    changes.add((songLength - alertEndSlack, nextLabel));
  }
  final marks = <AlertMark>[];
  for (final (at, label) in changes) {
    if (at - alertVoiceLead > 0) {
      marks.add(AlertMark(at - alertVoiceLead, AlertKind.voice, '$label in ten seconds'));
    }
    for (final n in [3, 2, 1]) {
      if (at - n > 0) marks.add(AlertMark(at - n.toDouble(), AlertKind.beep));
    }
    marks.add(AlertMark(at, AlertKind.go, label));
  }
  marks.sort((a, b) => a.at.compareTo(b.at));
  return marks;
}

/// The marks passed while playing from [prev] to [now] seconds. Only normal
/// forward playback counts: a seek, a skip back or the first position after
/// a track change ([prev] null) fires nothing, so jumping around never
/// triggers a burst of stale alerts.
List<AlertMark> dueAlerts(double? prev, double now, List<AlertMark> marks, {double maxStep = 1.5}) {
  if (prev == null || now <= prev || now - prev > maxStep) return const [];
  return [for (final m in marks) if (m.at > prev && m.at <= now) m];
}
