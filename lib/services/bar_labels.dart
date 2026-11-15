import '../models/step_plan.dart';

/// Label texts for one sub-activity on the waveform bar, richest first.
///
/// The bar is the only time-proportional view of a song, so it is worth
/// labelling, but the space each sub-activity gets varies from a few pixels to
/// most of the bar. The painter measures these in order and draws the first one
/// that fits; if even the last one is too wide it ellipsises that instead of
/// leaving the band blank.
List<String> labelCandidates(StepSegment s, {int? gear}) {
  final name = s.label.trim();
  if (name.isEmpty) return const [];
  final rpm = s.maxRpm > 0 ? rpmText(s.minRpm, s.maxRpm) : '';
  final longGear = gear == null ? '' : 'Gear $gear';
  final shortGear = gear == null ? '' : 'G$gear';

  final out = <String>[];
  void add(List<String> parts) {
    final t = parts.where((p) => p.isNotEmpty).join(' · ');
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }

  add([name, rpm, longGear]);
  add([name, rpm, shortGear]);
  add([name, rpm]);
  add([name, longGear]);
  add([name, shortGear]);
  add([name]);
  return out;
}
