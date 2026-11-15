import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/playback_controller.dart';
import 'lyrics_sources_dialog.dart';

Future<void> showPlaybackSettings(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _PlaybackSettings(),
);

class _PlaybackSettings extends StatelessWidget {
  const _PlaybackSettings();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Song transitions'),
    content: const SizedBox(width: 360, child: PlaybackSettingsPanel()),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

/// Gapless/crossfade, silence skipping, screen-on and lyrics sources; used in
/// the dialog above and in apps' settings screens.
class PlaybackSettingsPanel extends StatelessWidget {
  const PlaybackSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<PlaybackController>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RadioGroup<bool>(
          groupValue: s.crossfade,
          onChanged: (v) => s.setCrossfade(enabled: v),
          child: const Column(
            children: [
              RadioListTile<bool>(
                value: false,
                title: Text('Gapless'),
                subtitle: Text(
                  'The next song is pre-loaded and starts as this one ends.',
                ),
              ),
              RadioListTile<bool>(
                value: true,
                title: Text('Crossfade'),
                subtitle: Text(
                  'The end of this song fades into the start of the next.',
                ),
              ),
            ],
          ),
        ),
        if (s.crossfade)
          ListTile(
            title: Text('Fade length: ${s.fadeSec.toStringAsFixed(0)} s'),
            subtitle: Slider(
              min: 1,
              max: 12,
              divisions: 11,
              value: s.fadeSec.clamp(1, 12).toDouble(),
              onChanged: (v) => s.setCrossfade(seconds: v),
            ),
          ),
        SwitchListTile(
          value: s.skipSilence,
          onChanged: s.setSkipSilence,
          title: const Text('Skip leading silence'),
          subtitle: const Text('Jump past silence at the start of a song.'),
        ),
        SwitchListTile(
          value: s.levelLoudness,
          onChanged: s.setLevelLoudness,
          title: const Text('Even out loudness'),
          subtitle: const Text(
            'Turn loud songs down to match quieter ones (from the next song; '
            'needs loudness measured in analyze-this).',
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Activity change alerts'),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              for (final (type, label, icon) in const [
                ('voice', 'Voice at 10 s', Icons.record_voice_over_outlined),
                ('beep', 'Beeps 3-2-1', Icons.notifications_active_outlined),
                ('flash', 'Flash', Icons.flash_on_outlined),
                ('vibrate', 'Vibrate', Icons.vibration),
              ])
                FilterChip(
                  avatar: Icon(icon, size: 16),
                  label: Text(label),
                  selected: s.alerts.contains(type),
                  onSelected: (v) => s.setAlert(type, v),
                ),
            ]),
          ),
        ),
        if (s.supportsKeepScreenOn)
          SwitchListTile(
            value: s.keepScreenOn,
            onChanged: s.setKeepScreenOn,
            title: const Text('Keep screen on while playing'),
            subtitle: const Text('Only while Now Playing is open'),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.lyrics_outlined),
          title: const Text('Lyrics sources…'),
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => const LyricsSourcesDialog(),
          ),
        ),
      ],
    );
  }
}
