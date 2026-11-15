import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/step_plan.dart';
import '../services/library_service.dart';
import '../services/playback_controller.dart';
import 'step_icon.dart';
import 'timed_note_banner.dart';

String _clock(double sec) {
  final s = sec.isFinite ? sec.round().clamp(0, 359999) : 0;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
  return '${h > 0 ? '$h:' : ''}$mm:${r.toString().padLeft(2, '0')}';
}

/// Full-screen colour flash over [child] while an activity change alert is
/// showing (see [PlaybackController.alerts]).
class AlertFlashOverlay extends StatelessWidget {
  const AlertFlashOverlay({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PlaybackController>();
    final on = s.flashUntil != null;
    final scheme = Theme.of(context).colorScheme;
    return Stack(children: [
      Positioned.fill(child: child),
      Positioned.fill(
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: on ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Container(
              color: scheme.primary.withValues(alpha: 0.6),
              alignment: Alignment.center,
              padding: const EdgeInsets.all(24),
              child: on && s.flashLabel != null
                  ? FittedBox(
                      child: Text(s.flashLabel!,
                          style: const TextStyle(
                              fontSize: 64, fontWeight: FontWeight.bold, color: Colors.white)))
                  : null,
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Opens the full-screen class view for the instructor.
Future<void> showClassMode(BuildContext context) => Navigator.of(context)
    .push(MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const ClassModeScreen()));

/// A glanceable class view: the current activity with a countdown that runs
/// across all of its songs, what to ride now, what comes next and how far
/// through the class we are. Keeps the screen on while playing.
class ClassModeScreen extends StatefulWidget {
  const ClassModeScreen({super.key});

  @override
  State<ClassModeScreen> createState() => _ClassModeScreenState();
}

class _ClassModeScreenState extends State<ClassModeScreen> {
  late final PlaybackController _controller;

  @override
  void initState() {
    super.initState();
    _controller = context.read<PlaybackController>()..nowPlayingShown();
  }

  @override
  void dispose() {
    _controller.nowPlayingHidden();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PlaybackController>();
    return Theme(
      data: ThemeData(
          brightness: Brightness.dark,
          colorScheme: ColorScheme.fromSeed(
              seedColor: Theme.of(context).colorScheme.primary, brightness: Brightness.dark)),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: AlertFlashOverlay(
          child: SafeArea(
            child: s.current == null
                ? const Center(child: Text('Nothing playing'))
                : StreamBuilder<Duration>(
                    stream: s.player.positionStream,
                    builder: (context, snap) {
                      final pos = (snap.data ?? s.player.position).inMilliseconds / 1000;
                      return _ClassBody(state: s, planPos: pos - s.player.clipStart);
                    }),
          ),
        ),
      ),
    );
  }
}

class _ClassBody extends StatelessWidget {
  const _ClassBody({required this.state, required this.planPos});
  final PlaybackController state;
  final double planPos;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = state;
    final plan = s.currentPlan;
    final seg = plan?.segmentAt(planPos);
    final blocks = s.mixBlocks;
    final bi = s.mixBlockIndex;
    final block = bi >= 0 && bi < blocks.length ? blocks[bi] : null;
    final nextBlock = bi >= 0 && bi + 1 < blocks.length ? blocks[bi + 1] : null;
    final total = s.mixTotalSeconds;
    final elapsed = (s.mixSongStart + planPos).clamp(0.0, total > 0 ? total : double.infinity);

    final dur = s.player.duration;
    final songLeft = plan != null && plan.segments.isNotEmpty
        ? plan.segments.last.end - planPos
        : dur == null
            ? 0.0
            : dur.inMilliseconds / 1000 - s.player.position.inMilliseconds / 1000;
    final activityLeft = block != null ? block.end - elapsed : songLeft;
    final activity = block?.activity ?? plan?.activity ?? s.currentStep ?? baseName(s.current!);
    final lo = seg?.minRpm ?? plan?.minRpm, hi = seg?.maxRpm ?? plan?.maxRpm;
    final gear = s.gearAt(plan, seg);
    final multi = (plan?.segments.length ?? 0) > 1;
    final notes = [s.currentNote, plan?.notes?.trim()].whereType<String>().where((n) => n.isNotEmpty);

    Text big(String t, double size, {Color? color, FontWeight w = FontWeight.bold}) =>
        Text(t, maxLines: 1, style: TextStyle(fontSize: size, fontWeight: w, color: color));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(children: [
        Row(children: [
          IconButton(
              tooltip: 'Leave class mode',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).maybePop()),
          Expanded(
            child: total > 0
                ? Text('${_clock(elapsed)} in · ${_clock(total - elapsed)} to go',
                    textAlign: TextAlign.center, style: theme.textTheme.titleMedium)
                : const SizedBox.shrink(),
          ),
          IconButton(
            tooltip: s.player.playing ? 'Pause' : 'Play',
            iconSize: 32,
            icon: Icon(s.player.playing ? Icons.pause_circle : Icons.play_circle),
            onPressed: () => s.player.playing ? s.player.pause() : s.player.play(),
          ),
        ]),
        if (total > 0) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: (elapsed / total).clamp(0.0, 1.0), minHeight: 8),
          ),
        ],
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(iconForKey(seg?.icon ?? plan?.icon, fallbackName: activity), size: 56, color: scheme.primary),
            FittedBox(child: big(activity, 44)),
            if (multi && seg != null) FittedBox(child: big(seg.label, 30, color: scheme.secondary)),
            if (lo != null && hi != null) FittedBox(child: big(rpmText(lo, hi), 52, color: scheme.primary)),
            if (gear != null) big('${gear.text} (${gear.deltaText})', 22, w: FontWeight.w500),
            const SizedBox(height: 8),
            FittedBox(child: big(_clock(activityLeft), 120)),
            Text(block != null && block.songs > 1 ? 'left in this activity (${block.songs} songs)' : 'left in this activity',
                style: theme.textTheme.bodyMedium),
            if (multi && seg != null && seg.end - planPos < activityLeft - 1)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('${seg.label}: ${_clock(seg.end - planPos)} left${seg.cue != null ? ' · ${seg.cue}' : ''}${seg.note != null && seg.note!.isNotEmpty ? ' · 💬 ${seg.note}' : ''}',
                    style: theme.textTheme.titleMedium),
              ),
          ]),
        ),
        TimedNoteBanner(state: s, pos: planPos, big: true),
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('💬 $n',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(fontStyle: FontStyle.italic)),
          ),
        if (nextBlock != null) _NextUp(block: nextBlock, inSec: nextBlock.start - elapsed),
      ]),
    );
  }
}

class _NextUp extends StatelessWidget {
  const _NextUp({required this.block, required this.inSec});
  final MixBlock block;
  final double inSec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = block.plan;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(iconForKey(p?.icon, fallbackName: block.activity), size: 32),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
              'Next: ${block.activity}${p == null ? '' : ' · ${rpmText(p.minRpm, p.maxRpm)}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge),
        ),
        Text('in ${_clock(inSec)}', style: theme.textTheme.titleLarge),
      ]),
    );
  }
}
