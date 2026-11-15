import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/step_plan.dart';
import '../services/playback_controller.dart';

/// How long a trainer note stays on screen after its timestamp.
const timedNoteHold = 10.0;

/// Pops up the trainer note whose time has come (and speaks it once when
/// spoken advice is on). Shows nothing between notes.
class TimedNoteBanner extends StatefulWidget {
  const TimedNoteBanner({super.key, required this.state, required this.pos, this.big = false});
  final PlaybackController state;

  /// Seconds into the played clip, like segment starts.
  final double pos;
  final bool big;

  @override
  State<TimedNoteBanner> createState() => _TimedNoteBannerState();
}

class _TimedNoteBannerState extends State<TimedNoteBanner> {
  FlutterTts? _tts;
  TimedNote? _spoken;

  @override
  void dispose() {
    try {
      _tts?.stop();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = activeTimedNote(widget.state.currentTimedNotes, widget.pos, hold: timedNoteHold);
    if (note == null) {
      _spoken = null;
      return const SizedBox.shrink();
    }
    if (widget.state.speakAdvice && _spoken != note) {
      _spoken = note;
      try {
        _tts ??= FlutterTts();
        _tts!.speak(note.text).catchError((_) => null);
      } catch (_) {}
    }
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.tertiaryContainer,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Text('📝 ${note.text}',
            textAlign: widget.big ? TextAlign.center : TextAlign.start,
            style: (widget.big ? theme.textTheme.headlineSmall : theme.textTheme.titleMedium)
                ?.copyWith(color: theme.colorScheme.onTertiaryContainer)),
      ),
    );
  }
}

/// Pauses, asks for a note and stores it at the current position. Hidden
/// when the host cannot store notes.
class AddTimedNoteButton extends StatelessWidget {
  const AddTimedNoteButton({super.key, required this.state});
  final PlaybackController state;

  @override
  Widget build(BuildContext context) {
    final add = state.addTimedNote;
    final path = state.current;
    if (add == null || path == null) return const SizedBox.shrink();
    return IconButton(
      tooltip: 'Add a trainer note at this point',
      icon: const Icon(Icons.edit_note),
      onPressed: () async {
        final wasPlaying = state.player.playing;
        final at = state.player.position.inMilliseconds / 1000 - state.player.clipStart;
        await state.player.pause();
        if (!context.mounted) return;
        final c = TextEditingController();
        final text = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Note at ${at ~/ 60}:${(at % 60).floor().toString().padLeft(2, '0')}'),
            content: TextField(
                controller: c,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(hintText: 'e.g. Add a gear for the chorus')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Add')),
            ],
          ),
        );
        if (text != null && text.trim().isNotEmpty) {
          add(path, at, text.trim());
          await state.refreshPlans();
        }
        if (wasPlaying) await state.player.play();
      },
    );
  }
}
