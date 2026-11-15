import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/shared_core.dart';

StepSegment seg(String label, double a, double b,
        {double lo = 70, double hi = 80, bool lead = false, String icon = 'steady'}) =>
    StepSegment(
        label: label, icon: icon, start: a, end: b, minRpm: lo, maxRpm: hi, lead: lead);

void main() {
  group('labelCandidates', () {
    test('richest first, down to the bare name', () {
      expect(labelCandidates(seg('Climb 1/3', 0, 30), gear: 14), [
        'Climb 1/3 · 70–80 RPM · Gear 14',
        'Climb 1/3 · 70–80 RPM · G14',
        'Climb 1/3 · 70–80 RPM',
        'Climb 1/3 · Gear 14',
        'Climb 1/3 · G14',
        'Climb 1/3',
      ]);
    });

    test('without a gear there is no gear text', () {
      expect(labelCandidates(seg('Steady', 0, 15, lead: true)),
          ['Steady · 70–80 RPM', 'Steady']);
    });

    test('a single-value range and a blank name', () {
      expect(labelCandidates(seg('Peak', 0, 10, lo: 100, hi: 100)),
          ['Peak · 100 RPM', 'Peak']);
      expect(labelCandidates(seg('  ', 0, 10)), isEmpty);
    });
  });

  group('WaveformBar', () {
    Widget bar({StepPlan? plan, required void Function(double) onSeek}) =>
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: WaveformBar(
                wave: null,
                map: null,
                plan: plan,
                pos: 10,
                duration: 100,
                onSeek: onSeek,
              ),
            ),
          ),
        );

    final plan = StepPlan(activity: 'Hill climb', icon: 'hill', minRpm: 60, maxRpm: 90, segments: [
      seg('Flat road', 0, 15, lead: true),
      seg('Climb 1/3', 15, 50, icon: 'resistance'),
      seg('Return to speed', 50, 100, icon: 'spin'),
    ]);

    testWidgets('paints with a plan and still seeks to the exact spot', (tester) async {
      double? sought;
      await tester.pumpWidget(bar(plan: plan, onSeek: (v) => sought = v));
      expect(tester.takeException(), isNull);
      await tester.tapAt(tester.getTopLeft(find.byType(WaveformBar)) + const Offset(100, 30));
      expect(sought, closeTo(25, 0.5), reason: 'no snapping to a sub-activity start');
    });

    testWidgets('paints without a plan, and with one that has no segments', (tester) async {
      await tester.pumpWidget(bar(onSeek: (_) {}));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(bar(
          plan: const StepPlan(activity: 'x', icon: '', minRpm: 0, maxRpm: 0), onSeek: (_) {}));
      expect(tester.takeException(), isNull);
    });
  });
}
