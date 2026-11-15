import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/playback_controller.dart';

/// Cover art for a track (file-backed, downscaled), with a placeholder.
class TrackArt extends StatefulWidget {
  const TrackArt({super.key, required this.path, required this.size, this.downloadable = false});
  final String path;
  final double size;

  /// When the track has no art, tapping the placeholder downloads it (if the app supports it).
  final bool downloadable;

  @override
  State<TrackArt> createState() => _TrackArtState();
}

class _TrackArtState extends State<TrackArt> {
  @override
  void initState() {
    super.initState();
    context.read<PlaybackController>().ensureMedia(widget.path);
  }

  @override
  void didUpdateWidget(TrackArt old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) context.read<PlaybackController>().ensureMedia(widget.path);
  }

  @override
  Widget build(BuildContext context) {
    final art = context.select<PlaybackController, File?>((s) => s.media[widget.path]?.art);
    final loaded = context.select<PlaybackController, bool>((s) => s.media.containsKey(widget.path));
    final busy =
        context.select<PlaybackController, bool>((s) => s.artBusy.contains('s:${widget.path}'));
    final supported = context.read<PlaybackController>().supportsArtDownload;
    final theme = Theme.of(context);
    final canDownload =
        widget.downloadable && supported && loaded && art == null && widget.path.isNotEmpty;
    Widget placeholder = Container(
      width: widget.size,
      height: widget.size,
      color: theme.colorScheme.surfaceContainerHighest,
      child: busy
          ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))
          : Icon(canDownload ? Icons.download : Icons.music_note, size: widget.size * 0.5),
    );
    if (canDownload && !busy) {
      placeholder = Tooltip(
        message: 'Click to download album art',
        child: InkWell(
          onTap: () async {
            final s = context.read<PlaybackController>();
            final m = ScaffoldMessenger.of(context);
            final ok = await s.downloadAlbumArt(widget.path);
            m.showSnackBar(SnackBar(
                content: Text(ok ? 'Album art downloaded' : 'No album art found online')));
          },
          child: placeholder,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: art == null
          ? placeholder
          : Image.file(
              art,
              key: ValueKey(art.path),
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
              cacheWidth: (widget.size * 2).round(),
              errorBuilder: (_, _, _) => placeholder,
            ),
    );
  }
}
