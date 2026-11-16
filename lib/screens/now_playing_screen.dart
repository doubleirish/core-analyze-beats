import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';

import '../models/gear.dart';
import '../models/lyrics.dart';
import '../models/step_plan.dart';
import '../models/tempo.dart';
import '../services/algorithms.dart';
import '../services/call_out.dart';
import '../services/instructor.dart';
import '../services/library_service.dart';
import '../services/playback_controller.dart';
import 'beat_flash.dart';
import 'class_mode_screen.dart';
import 'playback_settings_dialog.dart';
import 'rating_bar.dart';
import 'sleep_timer.dart';
import 'spectrum_view.dart';
import 'step_icon.dart';
import 'timed_note_banner.dart';
import 'tempo_graph.dart';
import 'track_art.dart';
import 'waveform_bar.dart';

const nextSongPreviewSec = 30;

String _bpmAt(TempoMap m, double pos) {
  final s = m.segmentAt(pos);
  return s == null ? '—' : s.bpm.toStringAsFixed(0);
}

class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key, this.extraActions = const []});

  /// App-specific app-bar buttons, e.g. a "Play on…" output picker.
  final List<Widget> extraActions;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PlaybackController>();
    final path = s.current;
    return _ReportVisible(
        child: Scaffold(
      appBar: AppBar(
        title: const Text('Now playing'),
        actions: [
          ...extraActions,
          const SleepTimerButton(),
          if (path != null)
            IconButton(
              tooltip: 'Class mode (big countdown for the instructor)',
              icon: const Icon(Icons.fullscreen),
              onPressed: () => showClassMode(context),
            ),
          IconButton(
            tooltip: 'Song transitions (gapless / crossfade)',
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => showPlaybackSettings(context),
          ),
          if (path != null)
            IconButton(
              tooltip: 'Fetch art & lyrics',
              icon: s.fetching.contains(path)
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.lyrics_outlined),
              onPressed: s.fetching.contains(path) ? null : () => s.fetchMedia(path),
            ),
        ],
      ),
      body: path == null
          ? const Center(child: Text('Nothing playing'))
          : AlertFlashOverlay(
              child: StreamBuilder<Duration>(
                  stream: s.player.positionStream,
                  builder: (context, snap) {
                    final pos = (snap.data ?? s.player.position).inMilliseconds / 1000;
                    return _Body(state: s, path: path, pos: pos);
                  }),
            ),
    ));
  }
}

/// Tells the controller while Now Playing is on screen (for keep-screen-on).
class _ReportVisible extends StatefulWidget {
  const _ReportVisible({required this.child});
  final Widget child;

  @override
  State<_ReportVisible> createState() => _ReportVisibleState();
}

class _ReportVisibleState extends State<_ReportVisible> {
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
  Widget build(BuildContext context) => widget.child;
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.path, required this.pos});
  final PlaybackController state;
  final String path;
  final double pos;

  @override
  Widget build(BuildContext context) {
    final tm = state.mapOf(path);
    final total = state.player.duration?.inMilliseconds.toDouble() ??
        (tm?.durationSec ?? 0) * 1000;
    final dur = total / 1000;
    final remaining = dur - pos;
    final cur = tm?.segmentAt(pos);
    final nextSeg = tm?.nextSegmentAfter(pos);
    final nextPath = state.next;
    final nextTm = state.mapOf(nextPath);
    final results = state.tempos[path];
    final media = state.media[path];
    final theme = Theme.of(context);
    final title = media?.title ?? baseName(path);

    bool on(String id) => state.showView(id);
    final wide = MediaQuery.sizeOf(context).width >= 800;

    final infoSections = <Widget>[
      if ((tm == null && (on('algos') || on('graph') || on('countdowns'))) ||
          (tm != null && on('algos') && !state.isComplete(results)))
        Center(
          child: TextButton.icon(
            onPressed: state.analyzing.contains(path) ? null : () => state.analyze(path),
            icon: const Icon(Icons.analytics),
            label: Text(state.analyzing.contains(path)
                ? 'Analyzing…'
                : tm == null
                    ? 'Analyze tempo'
                    : 'Analyze all algorithms'),
          ),
        ),
      if (on('algos'))
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(alignment: WrapAlignment.center, spacing: 6, runSpacing: 4, children: [
            for (final a in allAlgorithms)
              if (results?.byAlgo.containsKey(a.id) ?? false)
                ChoiceChip(
                  selected: state.algorithm == a.id,
                  onSelected: (_) => state.setAlgorithm(a.id),
                  label: Text('${a.short} ${_bpmAt(results!.mapFor(a.id)!, pos)}'),
                  tooltip: a.name,
                ),
          ]),
        ),
      if (on('beat')) BeatFlash(state: state, path: path),
      if (on('spectrum'))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SpectrumView(path: path),
        ),
      if (on('graph') && tm != null && tm.segments.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TempoGraph(map: tm, playhead: pos, height: 110),
        ),
      if (on('next'))
        nextPath == null
            ? const Card(child: ListTile(title: Text('Up next: nothing (end of the list)')))
            : _NextSongCard(
                path: nextPath,
                tm: nextTm,
                soon: dur > 0 && remaining <= nextSongPreviewSec),
    ];

    final controls = <Widget>[
      WaveformBar(
        wave: state.waveOf(path),
        map: tm,
        plan: state.currentPlan,
        gearOf: (s) => state.gearAt(state.currentPlan, s)?.absolute,
        pos: pos,
        duration: dur,
        onSeek: (v) => state.player.seek(Duration(milliseconds: (v * 1000).round())),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(fmtTime(pos)), Text(fmtTime(dur))]),
      StreamBuilder<bool>(
        stream: state.player.playingStream,
        initialData: state.player.playing,
        builder: (_, snap) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
            tooltip: state.repeat ? 'Repeat: on' : 'Repeat: off',
            isSelected: state.repeat,
            icon: const Icon(Icons.repeat),
            selectedIcon: const Icon(Icons.repeat_on),
            onPressed: state.toggleRepeat,
          ),
          IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous), onPressed: state.playPrevious),
          IconButton(
            iconSize: 64,
            icon: Icon(snap.data == true ? Icons.pause_circle : Icons.play_circle),
            onPressed: () => snap.data == true ? state.player.pause() : state.player.play(),
          ),
          IconButton(
              iconSize: 40,
              icon: const Icon(Icons.skip_next),
              onPressed: state.next == null ? null : state.playNext),
          SizedBox(width: 48, child: AddTimedNoteButton(state: state)),
        ]),
      ),
    ];

    final bigStyle = theme.textTheme.displayMedium?.copyWith(color: theme.colorScheme.primary);
    final subtitle = [media?.artist, media?.album].whereType<String>().join(' · ');
    final String nextInValue, nextBpmLabel, nextBpmValue;
    if (nextSeg != null) {
      nextInValue = fmtTime((cur?.endSec ?? nextSeg.startSec) - pos);
      nextBpmLabel = 'Next BPM';
      nextBpmValue = nextSeg.bpm.toStringAsFixed(0);
    } else {
      nextInValue = nextPath == null ? '—' : fmtTime(remaining);
      nextBpmLabel = nextPath == null ? 'Next BPM' : 'Next song BPM';
      final first = nextTm?.firstBpm;
      nextBpmValue = nextPath == null || first == null ? '—' : first.toStringAsFixed(0);
    }
    final planned = (state.currentPlan?.segments.length ?? 0) > 1;
    // Plans are timed from the trimmed start of the song.
    final planPos = pos - state.player.clipStart;
    final seg = planned ? state.currentPlan!.segmentAt(planPos) : null;
    final stats = planned && seg != null && cur != null
        ? Wrap(spacing: 20, runSpacing: 4, children: [
            Text('Beat ${beatText(cur.bpm, seg)}', style: theme.textTheme.titleMedium),
            Text('Song ends in ${fmtTime(remaining)}', style: theme.textTheme.titleMedium),
          ])
        : Wrap(spacing: 28, runSpacing: 8, children: [
      _BigStat('Current BPM', cur == null ? '—' : cur.bpm.toStringAsFixed(0), bigStyle),
      if (on('countdowns')) ...[
        _BigStat('Next tempo in', nextInValue, bigStyle),
        _BigStat(nextBpmLabel, nextBpmValue, bigStyle),
        _BigStat('Song ends in', fmtTime(remaining), bigStyle),
      ],
    ]);
    final heading = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: theme.textTheme.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
      if (subtitle.isNotEmpty)
        Text(subtitle, style: theme.textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
      if (state.supportsRating && on('rating')) RatingBar(state: state, path: path),
      if (state.currentStep != null) ...[
        const SizedBox(height: 6),
        _ProgramStepBar(state: state, pos: planPos),
      ],
      TimedNoteBanner(state: state, pos: planPos),
      const SizedBox(height: 4),
      stats,
    ]);

    final lyrics = _LyricsPanel(
      lyrics: media?.lyrics,
      pos: pos,
      loaded: media != null,
      fetching: state.fetching.contains(path),
      note: state.enrichNote,
      onFetch: () => state.fetchMedia(path),
      onSeek: (t) => state.player.seek(Duration(milliseconds: (t * 1000).round())),
    );

    final showArt = on('art'), showLyrics = on('lyrics');
    final Widget content;
    if (wide) {
      content = Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          flex: 5,
          child: ListView(children: [
            if (showArt) Center(child: TrackArt(path: path, size: 280)),
            if (showArt) const SizedBox(height: 16),
            heading,
            const SizedBox(height: 12),
            ...infoSections,
          ]),
        ),
        if (showLyrics) ...[
          const SizedBox(width: 24),
          Expanded(flex: 4, child: lyrics),
        ],
      ]);
    } else {
      final head = Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        if (showArt) ...[TrackArt(path: path, size: 96), const SizedBox(width: 12)],
        Expanded(child: heading),
      ]);
      content = infoSections.isEmpty && showLyrics
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              head,
              const SizedBox(height: 8),
              Expanded(child: lyrics),
            ])
          : ListView(children: [
              head,
              const SizedBox(height: 8),
              ...infoSections,
              if (showLyrics) SizedBox(height: 320, child: lyrics),
            ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _ViewToggleBar(state: state),
      Expanded(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: wide ? 20 : 16, vertical: 8),
          child: content,
        ),
      ),
      Padding(
        padding: EdgeInsets.fromLTRB(wide ? 20 : 16, 0, wide ? 20 : 16, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: controls),
      ),
    ]);
  }
}

class _ViewToggleBar extends StatelessWidget {
  const _ViewToggleBar({required this.state});
  final PlaybackController state;

  static const _items = [
    ('art', 'Image', Icons.image_outlined),
    ('lyrics', 'Lyrics', Icons.lyrics_outlined),
    ('graph', 'Tempo graph', Icons.bar_chart),
    ('spectrum', 'Spectrum', Icons.equalizer),
    ('beat', 'Beat flash', Icons.flash_on_outlined),
    ('click', 'Click', Icons.notifications_active_outlined),
    ('algos', 'Algorithms', Icons.compare_arrows),
    ('countdowns', 'Countdowns', Icons.timer_outlined),
    ('next', 'Next song', Icons.skip_next_outlined),
    ('rating', 'Rating', Icons.star_outline),
  ];

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          for (final (id, label, icon) in _items)
            if (id != 'rating' || state.supportsRating)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                avatar: Icon(icon, size: 18),
                label: Text(label),
                selected: state.showView(id),
                onSelected: (_) => state.toggleView(id),
              ),
            ),
        ]),
      );
}

class _LyricsPanel extends StatefulWidget {
  const _LyricsPanel({
    required this.lyrics,
    required this.pos,
    required this.loaded,
    required this.fetching,
    required this.note,
    required this.onFetch,
    required this.onSeek,
  });

  final Lyrics? lyrics;
  final double pos;
  final bool loaded;
  final bool fetching;
  final String? note;
  final VoidCallback onFetch;
  final void Function(double) onSeek;

  @override
  State<_LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<_LyricsPanel> {
  final Map<int, GlobalKey> _keys = {};
  int _lastIndex = -2;
  Lyrics? _lastLyrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = widget.lyrics;
    if (l == null || l.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.loaded ? 'No lyrics yet' : 'Loading…', style: theme.textTheme.bodyLarge),
          if (widget.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(widget.note!, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
            ),
          const SizedBox(height: 8),
          if (widget.loaded)
            OutlinedButton.icon(
              onPressed: widget.fetching ? null : widget.onFetch,
              icon: const Icon(Icons.cloud_download),
              label: Text(widget.fetching ? 'Fetching…' : 'Fetch art & lyrics'),
            ),
        ]),
      );
    }
    if (!identical(l, _lastLyrics)) {
      _lastLyrics = l;
      _keys.clear();
      _lastIndex = -2;
    }
    final idx = l.indexAt(widget.pos);
    if (l.synced && idx != _lastIndex && idx >= 0) {
      _lastIndex = idx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _keys[idx]?.currentContext;
        if (ctx != null && ctx.mounted) {
          Scrollable.ensureVisible(ctx,
              alignment: 0.35, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
        }
      });
    }
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        for (var i = 0; i < l.lines.length; i++)
          InkWell(
            key: _keys.putIfAbsent(i, GlobalKey.new),
            onTap: l.synced ? () => widget.onSeek(l.lines[i].time) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Text(
                l.lines[i].text.isEmpty ? '♪' : l.lines[i].text,
                textAlign: TextAlign.center,
                style: (l.synced && i == idx
                        ? theme.textTheme.titleLarge?.copyWith(
                            color: theme.colorScheme.primary, fontWeight: FontWeight.bold)
                        : theme.textTheme.titleMedium)
                    ?.copyWith(
                        color: l.synced && i != idx
                            ? theme.colorScheme.onSurface.withValues(alpha: 0.55)
                            : null),
              ),
            ),
          ),
      ]),
    );
  }
}

class _ProgramStepBar extends StatelessWidget {
  const _ProgramStepBar({required this.state, required this.pos});
  final PlaybackController state;
  final double pos;

  static const _heads = 5.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = state.currentStep!;
    final plan = state.currentPlan;

    final seg = plan != null && plan.segments.length > 1 ? plan.segmentAt(pos) : null;
    final after = seg == null ? null : plan!.segmentAfter(pos);
    final nextSong = state.nextSongPlan?.segments.firstOrNull;
    final remaining = seg == null ? 0.0 : (seg.end - pos).clamp(0.0, 9999.0);
    final soon = seg != null && remaining <= _heads;
    final gear = state.gearAt(plan, seg);

    Widget rpm(String text) => Text(text, style: theme.textTheme.bodyMedium);

    final header = _MixTimeline(state: state, current: current, plan: plan, pos: pos);
    if (seg == null) {
      if (plan == null) return header;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        header,
        const SizedBox(height: 8),
        _InstructorCard(state: state, plan: plan, pos: pos),
      ]);
    }

    Widget upcoming() {
      final up = after ?? nextSong;
      if (up == null) return const SizedBox.shrink();
      final label = after != null || state.nextSongPlan?.activity == current
          ? up.label
          : '${state.nextSongPlan!.activity}: ${up.label}';
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: soon ? scheme.tertiaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(soon ? 'Get ready: ' : 'Next: ', style: theme.textTheme.bodyMedium),
          Icon(iconForKey(up.icon, fallbackName: up.label), size: 18),
          const SizedBox(width: 4),
          Flexible(
              child: Text('$label · ${callText(up, state.gearAt(after != null ? plan : state.nextSongPlan, up))}',
                  style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis)),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      header,
      const SizedBox(height: 6),
      _SegmentStrip(
          plan: plan!,
          seg: seg,
          onSelect: (s) => state.jumpTo(state.index, seconds: s.start)),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        color: scheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(iconForKey(seg.icon, fallbackName: seg.label), size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(seg.label, style: theme.textTheme.titleLarge),
                rpm(callText(seg, gear)),
                if (seg.cue != null) Text(seg.cue!, style: theme.textTheme.bodySmall),
                if (seg.note != null && seg.note!.isNotEmpty) Text('💬 ${seg.note}', style: theme.textTheme.bodySmall),
              ]),
            ),
            Text('${remaining.ceil()}s',
                style: theme.textTheme.displaySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
        ),
      ),
      if (gear != null) ...[const SizedBox(height: 6), _GearRow(state: state, gear: gear)],
      const SizedBox(height: 6),
      upcoming(),
      const SizedBox(height: 8),
      _InstructorCard(state: state, plan: plan, pos: pos),
    ]);
  }
}

/// Instructor helper: what to do now and what comes next, optionally spoken.
class _InstructorCard extends StatefulWidget {
  const _InstructorCard({required this.state, required this.plan, required this.pos});
  final PlaybackController state;
  final StepPlan plan;
  final double pos;

  @override
  State<_InstructorCard> createState() => _InstructorCardState();
}

class _InstructorCardState extends State<_InstructorCard> {
  FlutterTts? _tts;
  String? _spoken;

  @override
  void dispose() {
    try {
      _tts?.stop();
    } catch (_) {}
    super.dispose();
  }

  void _speak(String text) {
    if (_spoken == text) return;
    _spoken = text;
    try {
      _tts ??= FlutterTts();
      _tts!.speak(text).catchError((_) => null);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.state;
    final tips = instructorAdvice(
        prev: s.prevPlan, cur: widget.plan, nextSong: s.nextSongPlan, pos: widget.pos);
    final partNotes = widget.plan.notes?.trim();
    final songNote = s.currentNote;
    if (tips.now == null && tips.next == null && songNote == null && (partNotes ?? '').isEmpty) {
      return const SizedBox.shrink();
    }
    // The song's own cue is spoken once as it starts, then the advice.
    if (s.speakAdvice) {
      if (songNote != null && widget.pos < 8) {
        _speak(songNote);
      } else if (tips.now != null) {
        _speak(tips.now!.text);
      }
    }

    Widget line(String label, Advice a, TextStyle? style) => Row(children: [
          Icon(iconForKey(a.icon, fallbackName: a.text), size: 18),
          const SizedBox(width: 6),
          Expanded(child: Text.rich(TextSpan(children: [
            TextSpan(text: '$label ', style: const TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: a.text),
          ]), style: style)),
        ]);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Instructor', style: theme.textTheme.labelSmall),
              if (songNote != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('💬 $songNote',
                      style: theme.textTheme.bodyLarge?.copyWith(
                          fontStyle: FontStyle.italic, color: theme.colorScheme.primary)),
                ),
              if (tips.now != null) line('Now:', tips.now!, theme.textTheme.bodyLarge),
              if (tips.next != null) ...[
                const SizedBox(height: 2),
                line('Next:', tips.next!, theme.textTheme.bodyMedium),
              ],
              if (partNotes != null && partNotes.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(partNotes,
                    maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
              ],
            ]),
          ),
          IconButton(
            tooltip: s.speakAdvice ? 'Mute spoken advice' : 'Speak advice',
            icon: Icon(s.speakAdvice ? Icons.volume_up : Icons.volume_off),
            onPressed: () {
              _spoken = null;
              s.setSpeakAdvice(!s.speakAdvice);
            },
          ),
        ]),
      ),
    );
  }
}

/// The whole mix as one progress bar: a block per activity sized by its
/// length and filled as it is ridden, with the current activity and as many
/// of the following ones as fit underneath.
class _MixTimeline extends StatelessWidget {
  const _MixTimeline(
      {required this.state, required this.current, required this.plan, required this.pos});
  final PlaybackController state;
  final String current;
  final StepPlan? plan;
  final double pos;

  static String _clock(double sec) {
    final s = sec.round();
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, r = s % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : '$m';
    return '${h > 0 ? '$h:' : ''}$mm:${r.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blocks = state.mixBlocks;
    final cur = state.mixBlockIndex;
    final total = state.mixTotalSeconds;
    final elapsed = (state.mixSongStart + pos).clamp(0.0, total);

    Widget chip(String name, StepPlan? p, {required bool active, VoidCallback? onTap}) => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? scheme.primaryContainer : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            border: active ? Border.all(color: scheme.primary, width: 2) : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(iconForKey(p?.icon, fallbackName: name), size: 18),
            const SizedBox(width: 4),
            Text(p == null ? name : '$name · ${rpmText(p.minRpm, p.maxRpm)}',
                style: active ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium),
          ]),
        ));

    if (blocks.isEmpty || cur < 0 || total <= 0) {
      return Align(alignment: Alignment.centerLeft, child: chip(current, plan, active: true));
    }

    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      const gap = 2.0;
      final usable = width - gap * (blocks.length - 1);

      Widget block(int i) {
        final b = blocks[i];
        final w = (usable * b.seconds / total).clamp(2.0, usable);
        final done = i < cur ? 1.0 : i == cur ? ((elapsed - b.start) / b.seconds).clamp(0.0, 1.0) : 0.0;
        final p = b.plan;
        return GestureDetector(
          onTap: () => state.jumpTo(b.firstSong),
          child: Tooltip(
          message: '${b.activity}${p == null ? '' : ' · ${rpmText(p.minRpm, p.maxRpm)}'}'
              ' · ${_clock(b.seconds)}',
          child: Container(
            width: w,
            height: 30,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
              border: i == cur ? Border.all(color: scheme.primary, width: 2) : null,
            ),
            child: Stack(alignment: Alignment.center, children: [
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: done,
                  child: ColoredBox(
                      color: i == cur ? scheme.primary.withValues(alpha: 0.55) : scheme.primary.withValues(alpha: 0.30),
                      child: const SizedBox.expand()),
                ),
              ),
              if (w >= 24) Icon(iconForKey(p?.icon, fallbackName: b.activity), size: 16),
            ]),
          ),
        ));
      }

      // Chips for the current activity and as many following ones as fit.
      const chipChrome = 64.0;
      var used = 0.0;
      final chips = <Widget>[];
      var shown = 0;
      for (var i = cur; i < blocks.length; i++) {
        final b = blocks[i];
        final label = b.plan == null ? b.activity : '${b.activity} · ${rpmText(b.plan!.minRpm, b.plan!.maxRpm)}';
        final need = chipChrome + label.length * 7.0 + (i == cur ? 0 : 20);
        if (i > cur && used + need > width - 40) break;
        used += need;
        if (i > cur) chips.add(Icon(Icons.chevron_right, size: 20, color: scheme.outline));
        chips.add(i == cur
            ? chip(current, plan, active: true, onTap: () => state.jumpTo(b.firstSong))
            : chip(b.activity, b.plan, active: false, onTap: () => state.jumpTo(b.firstSong)));
        shown++;
      }
      final more = blocks.length - cur - shown;

      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            block(i),
          ],
        ]),
        const SizedBox(height: 4),
        Text(
            'Song ${state.index + 1} of ${state.queue.length} · ${_clock(elapsed)} / ${_clock(total)} · '
            '${(elapsed / total * 100).round()}% · ${_clock(total - elapsed)} left',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        ClipRect(
          child: Row(children: [
            ...chips,
            if (more > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text('+$more more', style: theme.textTheme.bodySmall),
              ),
          ]),
        ),
      ]);
    });
  }
}

/// Secondary row: every sub-activity of the current song (e.g. each tabata
/// round), with the current one highlighted and kept in view.
class _SegmentStrip extends StatefulWidget {
  const _SegmentStrip({required this.plan, required this.seg, required this.onSelect});
  final StepPlan plan;
  final StepSegment seg;
  final void Function(StepSegment) onSelect;

  @override
  State<_SegmentStrip> createState() => _SegmentStripState();
}

class _SegmentStripState extends State<_SegmentStrip> {
  final _currentKey = GlobalKey();

  @override
  void didUpdateWidget(_SegmentStrip old) {
    super.didUpdateWidget(old);
    if (!identical(old.seg, widget.seg)) _reveal();
  }

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _currentKey.currentContext;
        if (ctx != null && mounted) {
          Scrollable.ensureVisible(ctx,
              duration: const Duration(milliseconds: 300), alignment: 0.3, curve: Curves.easeOut);
        }
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final segs = widget.plan.segments;
    final curIndex = segs.indexWhere((s) => identical(s, widget.seg));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (var i = 0; i < segs.length; i++)
          Padding(
            key: i == curIndex ? _currentKey : null,
            padding: const EdgeInsets.only(right: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => widget.onSelect(segs[i]),
              child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: i == curIndex
                    ? scheme.primary
                    : i < curIndex
                        ? scheme.surfaceContainerLow
                        : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(iconForKey(segs[i].icon, fallbackName: segs[i].label),
                    size: 14, color: i == curIndex ? scheme.onPrimary : null),
                const SizedBox(width: 3),
                Text(segs[i].label,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: i == curIndex
                            ? scheme.onPrimary
                            : i < curIndex
                                ? scheme.outline
                                : null)),
              ]),
            ),
            ),
          ),
      ]),
    );
  }
}

class _NextSongCard extends StatelessWidget {
  const _NextSongCard({required this.path, required this.tm, this.soon = false});
  final String path;
  final TempoMap? tm;
  final bool soon;

  @override
  Widget build(BuildContext context) => Card(
        color: soon ? Theme.of(context).colorScheme.primaryContainer : null,
        child: ListTile(
          leading: TrackArt(path: path, size: 48),
          title: Text('Up next: ${baseName(path)}', maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SongActivity(path: path),
            Text(tm?.firstBpm == null
                ? 'Starting tempo unknown (not analyzed)'
                : 'Starts at ${tm!.firstBpm!.toStringAsFixed(0)} BPM'),
          ]),
        ),
      );
}

/// The main activity (and RPM range) planned for the song at [path]; empty if it has no plan.
class SongActivity extends StatelessWidget {
  const SongActivity({super.key, required this.path});
  final String path;

  @override
  Widget build(BuildContext context) => FutureBuilder<StepPlan?>(
        future: context.read<PlaybackController>().planOf(path),
        builder: (context, snap) {
          final plan = snap.data;
          if (plan == null || plan.activity.isEmpty) return const SizedBox.shrink();
          return Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(iconForKey(plan.icon, fallbackName: plan.activity), size: 16),
            const SizedBox(width: 4),
            Flexible(
                child: Text('${plan.activity} · ${rpmText(plan.minRpm, plan.maxRpm)}',
                    overflow: TextOverflow.ellipsis)),
          ]);
        },
      );
}

class _BigStat extends StatelessWidget {
  const _BigStat(this.label, this.value, this.style);
  final String label;
  final String value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          Text(value, style: style),
        ],
      );
}

/// The gear to call out, with - / + to move the base gear for the whole class
/// (long-press resets it).
class _GearRow extends StatelessWidget {
  const _GearRow({required this.state, required this.gear});
  final PlaybackController state;
  final GearCall gear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Text(gear.text,
          style: theme.textTheme.headlineMedium?.copyWith(color: theme.colorScheme.primary)),
      const SizedBox(width: 8),
      Chip(label: Text(gear.deltaText), visualDensity: VisualDensity.compact),
      const Spacer(),
      Text('Base ${state.baseGear}', style: theme.textTheme.bodySmall),
      IconButton(
          tooltip: 'Base gear down',
          icon: const Icon(Icons.remove_circle_outline),
          onPressed: () => state.nudgeBaseGear(-1)),
      GestureDetector(
        onLongPress: () => state.setBaseGear(12),
        child: IconButton(
            tooltip: 'Base gear up (hold to reset)',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => state.nudgeBaseGear(1)),
      ),
    ]);
  }
}
