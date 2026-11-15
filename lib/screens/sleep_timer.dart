import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/playback_controller.dart';

String _left(Duration d) {
  if (d.isNegative) return '0:00';
  final m = d.inMinutes;
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

String stopLabel(PlaybackController s) {
  switch (s.stopMode) {
    case StopMode.none:
      return 'Off';
    case StopMode.minutes:
      final at = s.stopAt;
      return at == null ? 'Timer' : _left(at.difference(DateTime.now()));
    case StopMode.endOfSong:
      return 'End of song';
    case StopMode.endOfMix:
      return 'End of mix';
  }
}

Future<void> showSleepTimer(BuildContext context) {
  final s = context.read<PlaybackController>();
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(title: Text('Stop playing (fades out)')),
          for (final m in const [15, 30, 45, 60])
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text('After $m minutes'),
              selected: s.stopMode == StopMode.minutes,
              onTap: () {
                s.setStopTimer(StopMode.minutes, minutes: m);
                Navigator.pop(ctx);
              },
            ),
          ListTile(
            leading: const Icon(Icons.music_note),
            title: const Text('At the end of this song'),
            selected: s.stopMode == StopMode.endOfSong,
            onTap: () {
              s.setStopTimer(StopMode.endOfSong);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: const Text('At the end of the mix'),
            selected: s.stopMode == StopMode.endOfMix,
            onTap: () {
              s.setStopTimer(StopMode.endOfMix);
              Navigator.pop(ctx);
            },
          ),
          if (s.stopMode != StopMode.none)
            ListTile(
              leading: const Icon(Icons.timer_off_outlined),
              title: const Text('Turn timer off'),
              onTap: () {
                s.cancelStopTimer();
                Navigator.pop(ctx);
              },
            ),
        ],
      ),
    ),
  );
}

/// Timer button that shows a live countdown while a sleep timer is armed.
class SleepTimerButton extends StatefulWidget {
  const SleepTimerButton({super.key});

  @override
  State<SleepTimerButton> createState() => _SleepTimerButtonState();
}

class _SleepTimerButtonState extends State<SleepTimerButton> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = context.read<PlaybackController>();
      if (s.stopMode == StopMode.minutes && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PlaybackController>();
    final on = s.stopMode != StopMode.none;
    return TextButton.icon(
      onPressed: () => showSleepTimer(context),
      icon: Icon(on ? Icons.bedtime : Icons.bedtime_outlined, size: 20),
      label: Text(on ? stopLabel(s) : 'Sleep'),
    );
  }
}
