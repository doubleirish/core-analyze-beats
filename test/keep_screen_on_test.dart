import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_core/screens/now_playing_screen.dart';
import 'package:shared_core/services/keep_screen_on.dart';
import 'package:shared_core/services/playback_controller.dart';

class _Controller extends PlaybackController {
  _Controller() : super(appId: 'test');
  @override
  List<String> get libraryPaths => const [];
  @override
  List<String> get mixPaths => const [];
}

void main() {
  testWidgets('Now Playing reports itself visible only while mounted', (tester) async {
    final c = _Controller();
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ChangeNotifierProvider<PlaybackController>.value(
      value: c,
      child: MaterialApp(navigatorKey: nav, home: const SizedBox()),
    ));
    expect(c.nowPlayingVisible, isFalse);
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const NowPlayingScreen()));
    await tester.pumpAndSettle();
    expect(c.nowPlayingVisible, isTrue);
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(c.nowPlayingVisible, isFalse);
  });

  late List<bool> calls;
  late KeepScreenOnGate gate;

  setUp(() {
    calls = [];
    gate = KeepScreenOnGate(calls.add);
  });

  void update({bool supported = true, bool enabled = true, bool playing = true}) =>
      gate.update(supported: supported, enabled: enabled, playing: playing);

  test('turns on only when supported, enabled, visible and playing', () {
    update();
    expect(calls, isEmpty, reason: 'not visible yet');
    gate.shown();
    update(supported: false);
    update(enabled: false);
    update(playing: false);
    expect(calls, isEmpty);
    update();
    expect(calls, [true]);
  });

  test('applies only on changes', () {
    gate.shown();
    update();
    update();
    update(playing: false);
    update(playing: false);
    update();
    expect(calls, [true, false, true]);
  });

  test('any condition dropping turns it off', () {
    gate.shown();
    for (final drop in <void Function()>[
      () => update(supported: false),
      () => update(enabled: false),
      () => update(playing: false),
    ]) {
      update();
      drop();
    }
    update();
    gate.hidden();
    update();
    expect(calls, [true, false, true, false, true, false, true, false]);
  });

  test('stays on until every shown view is hidden', () {
    gate
      ..shown()
      ..shown();
    update();
    gate.hidden();
    update();
    expect(gate.visible, isTrue);
    expect(calls, [true]);
    gate.hidden();
    update();
    expect(calls, [true, false]);
    gate.hidden(); // extra hide must not make the next show a no-op
    gate.shown();
    update();
    expect(calls, [true, false, true]);
  });

  test('close turns it off once and ignores later updates', () {
    gate.shown();
    update();
    gate.close();
    gate.close();
    update();
    expect(calls, [true, false]);
    expect(gate.on, isFalse);
  });

  test('close while off does not apply', () {
    gate.close();
    expect(calls, isEmpty);
  });
}
