import 'package:flutter/material.dart';

import '../services/metronome.dart';
import '../services/playback_controller.dart';

/// A dot that flashes on every beat of the current tempo segment.
class BeatFlash extends StatelessWidget {
  const BeatFlash({super.key, required this.state, required this.path});
  final PlaybackController state;
  final String path;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _BeatTicker(
      builder: (_) {
        final phase = state.player.playing
            ? state.beatPhaseAt(path, state.player.position.inMilliseconds / 1000)
            : null;
        final level = phase == null ? 0.0 : flashLevel(phase);
        return Container(
          height: 40,
          alignment: Alignment.center,
          child: Container(
            width: 24 + 16 * level,
            height: 24 + 16 * level,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color.lerp(cs.surfaceContainerHighest, cs.primary, level),
            ),
          ),
        );
      },
    );
  }
}

class _BeatTicker extends StatefulWidget {
  const _BeatTicker({required this.builder});
  final WidgetBuilder builder;

  @override
  State<_BeatTicker> createState() => _BeatTickerState();
}

class _BeatTickerState extends State<_BeatTicker> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _c, builder: (c, _) => widget.builder(c));
}
