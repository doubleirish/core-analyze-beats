import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

StepSegment seg(String label, {int? gear, double lo = 70, double hi = 80}) => StepSegment(
    label: label, icon: 'steady', start: 0, end: 10, minRpm: lo, maxRpm: hi, gear: gear);

void main() {
  test('gear is clamped to the Keiser scale', () {
    expect(absoluteGear(23, 5), 24);
    expect(absoluteGear(2, -4), 1);
    expect(gearCall(12, 2)!.text, 'Gear 14');
    expect(gearCall(12, 2)!.deltaText, '+2');
    expect(gearCall(12, 0)!.deltaText, 'base');
    expect(gearCall(12, -2)!.deltaText, '−2');
    expect(gearCall(12, null), isNull);
  });

  test('gear fields round-trip, and old plans without them still load', () {
    final plan = StepPlan(
        activity: 'a', icon: 'x', minRpm: 60, maxRpm: 80, baseGear: 10, segments: [seg('s', gear: 3)]);
    final back = StepPlan.fromJson(plan.toJson());
    expect(back.baseGear, 10);
    expect(back.segments.single.gear, 3);
    final old = StepPlan.fromJson({'activity': 'a', 'segments': [{'label': 's'}]});
    expect(old.baseGear, isNull);
    expect(old.segments.single.gear, isNull);
    expect(old.segments.single.toJson().containsKey('gear'), isFalse);
  });

  test('beatCall folds the music BPM into the band', () {
    expect(beatCall(75, 70, 80).tag, 'on the beat');
    final half = beatCall(150, 70, 80);
    expect((half.rpm, half.tag), (75.0, '½ beat'));
    expect(beatCall(40, 70, 90).tag, '2× beat');
    expect(beatCall(110, 70, 80).tag, 'off the beat');
  });

  test('call text and lock-screen lines', () {
    final s = seg('Stand', gear: 2);
    final g = gearCall(12, 2);
    expect(callText(s, g), '70–80 RPM · Gear 14');
    expect(callText(s, null), '70–80 RPM');
    expect(changeText(s, g), 'Stand · 70–80 RPM · Gear 14 (+2)');
    final l = lockScreenLines(s, g, seg('Sit', gear: 0), gearCall(12, 0));
    expect(l.subtitle, 'Stand · 70–80 RPM · Gear 14');
    expect(l.next, 'Next: Sit · 70–80 RPM · Gear 12');
    expect(lockScreenLines(s, null, null, null).next, isNull);
    expect(callChanges(s, g, seg('Sit', gear: 0), gearCall(12, 0)), isTrue);
    expect(callChanges(s, g, seg('Other', gear: 2), g), isFalse);
  });
}
