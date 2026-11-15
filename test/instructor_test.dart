import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

StepSegment seg(String label, String icon, double a, double b,
        {double lo = 80, double hi = 90, String? cue, bool lead = false}) =>
    StepSegment(
        label: label, icon: icon, start: a, end: b, minRpm: lo, maxRpm: hi, cue: cue, lead: lead);

StepPlan plan(String name, String icon, List<StepSegment> segs, {double lo = 80, double hi = 90}) =>
    StepPlan(activity: name, icon: icon, minRpm: lo, maxRpm: hi, segments: segs);

void main() {
  final hill = plan('Hill Climb', 'hill', [
    seg('Flat road', 'steady', 0, 15, lead: true),
    seg('Climb 1/2', 'resistance', 15, 60),
    seg('Summit', 'summit', 60, 105),
    seg('Return to speed', 'spin', 105, 130),
    seg('Flat road', 'steady', 130, 145, lead: true, cue: 'Ease back and recover'),
  ]);
  final sprint = plan('Sprint', 'sprint', [seg('Sprint', 'sprint', 0, 200, lo: 95, hi: 105)],
      lo: 95, hi: 105);

  test('activity start says reset; hill steps add 2', () {
    final t = instructorAdvice(cur: hill, pos: 3);
    expect(t.now!.text, 'Reset to your base resistance');
    expect(t.next!.text, 'Add 2 to your base resistance');
    expect(instructorAdvice(cur: hill, pos: 20).now!.text, 'Add 2 to your base resistance');
  });

  test('sprint after a hill climb resets and gives the top RPM; hill shows it as next', () {
    expect(instructorAdvice(prev: hill, cur: sprint, pos: 1).now!.text,
        'Reset to base resistance and hit 105 RPM');
    expect(instructorAdvice(cur: hill, nextSong: sprint, pos: 140).next!.text,
        'Reset to base resistance and hit 105 RPM');
  });

  test('tabata states work and rest lengths', () {
    final tab = plan('Tabata', 'tabata', [
      seg('Steady', 'steady', 0, 15, lead: true),
      seg('Work', 'work', 15, 35, cue: 'Round 1 · all out'),
      seg('Rest', 'rest', 35, 45, cue: 'Round 1 · easy spin'),
      seg('Steady', 'steady', 45, 60, lead: true),
    ]);
    final t = instructorAdvice(cur: tab, pos: 20);
    expect(t.now!.text, 'Round 1: all out for 20 s, then rest 10 s');
    expect(t.next!.text, 'Round 1: rest for 10 s');
  });

  test('warm-up gives rotating shoulder stretches; last cool-down gives off-bike stretches', () {
    final warm = plan('Warm-up', 'warmup', [seg('Warm-up', 'warmup', 0, 300)]);
    expect(instructorAdvice(cur: warm, pos: 2).now!.text, 'Reset to your base resistance');
    expect(instructorAdvice(cur: warm, pos: 20).now!.text, warmupStretches[0]);
    expect(instructorAdvice(cur: warm, pos: 50).now!.text, warmupStretches[1]);
    final cool = plan('Cool-down', 'cooldown', [seg('Cool-down', 'cooldown', 0, 200)]);
    expect(instructorAdvice(cur: cool, pos: 5).now!.text, cooldownStretches[0]);
    expect(instructorAdvice(cur: cool, nextSong: warm, pos: 5).now!.text,
        'Reset to your base resistance');
    expect(instructorAdvice(cur: cool, nextSong: warm, pos: 30).now!.text,
        'Drop to a light gear and breathe deeply');
  });
}
