import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/algorithms.dart';
import '../services/library_service.dart';
import '../services/playback_controller.dart';
import '../services/queue_service.dart';
import 'now_playing_screen.dart';
import 'playback_settings_dialog.dart';
import 'sleep_timer.dart';

/// Always-visible playback strip: transport, queue mode, repeat, algorithm, settings.
/// One row on wide windows; on narrow ones the options sit on a scrollable second row.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, this.extraActions = const []});

  /// App-specific buttons shown with the options (e.g. an output picker).
  final List<Widget> extraActions;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PlaybackController>();
    final path = s.current;
    final title = path == null
        ? 'Nothing playing'
        : (s.media[path]?.title ?? baseName(path));
    void openNowPlaying() => Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NowPlayingScreen()),
    );

    final transport = <Widget>[
      IconButton(
        tooltip: 'Previous',
        icon: const Icon(Icons.skip_previous),
        onPressed: path == null ? null : s.playPrevious,
      ),
      StreamBuilder<bool>(
        stream: s.player.playingStream,
        initialData: s.player.playing,
        builder: (_, snap) => IconButton(
          tooltip: snap.data == true ? 'Pause' : 'Play',
          icon: Icon(snap.data == true ? Icons.pause : Icons.play_arrow),
          onPressed: path == null
              ? null
              : () => snap.data == true ? s.player.pause() : s.player.play(),
        ),
      ),
      IconButton(
        tooltip: 'Next',
        icon: const Icon(Icons.skip_next),
        onPressed: path == null || s.next == null ? null : s.playNext,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: InkWell(
          onTap: path == null ? null : openNowPlaying,
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    ];
    final options = <Widget>[
      SegmentedButton<PlayMode>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: PlayMode.alphabetical,
            icon: Icon(Icons.sort_by_alpha),
            tooltip: 'Songs list A–Z',
          ),
          ButtonSegment(
            value: PlayMode.shuffle,
            icon: Icon(Icons.shuffle),
            tooltip: 'Shuffle songs list',
          ),
          ButtonSegment(
            value: PlayMode.mix,
            icon: Icon(Icons.queue_music),
            tooltip: 'Play the mix in order',
          ),
        ],
        selected: {s.mode},
        onSelectionChanged: (v) => s.setMode(v.first),
      ),
      IconButton(
        tooltip: s.repeat ? 'Repeat on' : 'Repeat off',
        icon: Icon(
          Icons.repeat,
          color: s.repeat ? Theme.of(context).colorScheme.primary : null,
        ),
        onPressed: s.toggleRepeat,
      ),
      DropdownButton<String>(
        value: s.algorithm,
        underline: const SizedBox.shrink(),
        items: [
          for (final a in allAlgorithms)
            DropdownMenuItem(value: a.id, child: Text(a.name)),
        ],
        onChanged: (v) => v == null ? null : s.setAlgorithm(v),
      ),
      const SleepTimerButton(),
      ...extraActions,
      IconButton(
        tooltip: 'Playback settings',
        icon: const Icon(Icons.tune),
        onPressed: () => showPlaybackSettings(context),
      ),
      IconButton(
        tooltip: 'Now playing',
        icon: StreamBuilder<bool>(
          stream: s.player.playingStream,
          initialData: s.player.playing,
          builder: (_, snap) =>
              _NowPlayingIcon(active: path != null && snap.data == true),
        ),
        onPressed: path == null ? null : openNowPlaying,
      ),
    ];

    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: LayoutBuilder(
            builder: (_, box) => box.maxWidth >= 900
                ? Row(children: [...transport, ...options])
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: transport),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: options),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _NowPlayingIcon extends StatefulWidget {
  const _NowPlayingIcon({required this.active});
  final bool active;

  @override
  State<_NowPlayingIcon> createState() => _NowPlayingIconState();
}

class _NowPlayingIconState extends State<_NowPlayingIcon>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final _scale = Tween<double>(
    begin: 1,
    end: 1.25,
  ).chain(CurveTween(curve: Curves.easeInOut)).animate(_pulse);

  void _sync() {
    if (widget.active && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_NowPlayingIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _scale,
    child: Icon(
      Icons.graphic_eq,
      color: widget.active ? Theme.of(context).colorScheme.primary : null,
    ),
  );
}
