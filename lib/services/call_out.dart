import '../models/gear.dart';
import '../models/step_plan.dart';
import 'rpm.dart';

/// "70–80 RPM · Gear 14" for one sub-activity; the gear is left out when unknown.
String callText(StepSegment s, GearCall? gear) =>
    [rpmText(s.minRpm, s.maxRpm), if (gear != null) gear.text].join(' · ');

/// What to say when moving from [from] to [to], e.g. "Stand · 70–80 RPM · Gear 14 (+2)".
String changeText(StepSegment to, GearCall? gear) =>
    '${to.label} · ${callText(to, gear)}${gear == null ? '' : ' (${gear.deltaText})'}';

/// Whether moving between two sub-activities changes the RPM range or the gear.
bool callChanges(StepSegment a, GearCall? ga, StepSegment b, GearCall? gb) =>
    a.minRpm.round() != b.minRpm.round() ||
    a.maxRpm.round() != b.maxRpm.round() ||
    ga?.absolute != gb?.absolute;

/// The beat as ridden, e.g. "75 · ½ beat" for a 150 BPM song in a 70–80 band.
String beatText(double bpm, StepSegment s) {
  final b = beatCall(bpm, s.minRpm, s.maxRpm);
  return '${b.rpm.round()} · ${b.tag}';
}

/// Lock-screen subtitle and description for a segment, e.g.
/// "Stand · 70–80 RPM · Gear 14" and "Next: Sit · 80–90 RPM · Gear 12".
({String subtitle, String? next}) lockScreenLines(
        StepSegment seg, GearCall? gear, StepSegment? upcoming, GearCall? upcomingGear) =>
    (
      subtitle: '${seg.label} · ${callText(seg, gear)}',
      next: upcoming == null ? null : 'Next: ${upcoming.label} · ${callText(upcoming, upcomingGear)}',
    );
