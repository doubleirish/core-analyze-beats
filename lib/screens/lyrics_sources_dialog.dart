import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/lyrics_sources.dart';
import '../services/playback_controller.dart';

class LyricsSourcesDialog extends StatefulWidget {
  const LyricsSourcesDialog({super.key});

  @override
  State<LyricsSourcesDialog> createState() => _LyricsSourcesDialogState();
}

class _LyricsSourcesDialogState extends State<LyricsSourcesDialog> {
  late final TextEditingController _token;

  @override
  void initState() {
    super.initState();
    _token = TextEditingController(text: context.read<PlaybackController>().enricher.geniusToken ?? '');
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PlaybackController>();
    return AlertDialog(
      title: const Text('Lyrics sources'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Synced sources are tried first, then plain-text ones.'),
            const SizedBox(height: 8),
            for (final src in allLyricsSources)
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(src.name),
                subtitle: Text(src.synced ? 'synced' : 'plain text'),
                value: !s.enricher.disabledSources.contains(src.id),
                onChanged: (v) => s.setLyricsSource(src.id, v),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _token,
              decoration: const InputDecoration(
                labelText: 'Genius API access token',
                helperText: 'Required for Genius; skipped when empty',
              ),
              onChanged: s.setGeniusToken,
            ),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
    );
  }
}
