import 'package:flutter/material.dart';

import '../services/mix_icon_spec.dart';
import 'track_art.dart';

/// The icons a mixtape can use, by stable key (stored in [MixIconSpec.name]).
/// Named constants rather than code points so release builds keep them.
const mixIconChoices = <String, IconData>{
  'bike': Icons.directions_bike,
  'run': Icons.directions_run,
  'gym': Icons.fitness_center,
  'climb': Icons.terrain,
  'speed': Icons.speed,
  'fire': Icons.local_fire_department,
  'bolt': Icons.bolt,
  'heart': Icons.favorite,
  'timer': Icons.timer,
  'trend': Icons.trending_up,
  'waves': Icons.waves,
  'calm': Icons.self_improvement,
  'spa': Icons.spa,
  'sun': Icons.wb_sunny,
  'night': Icons.nights_stay,
  'party': Icons.celebration,
  'star': Icons.star,
  'trophy': Icons.emoji_events,
  'flag': Icons.sports_score,
  'music': Icons.music_note,
  'headphones': Icons.headphones,
  'eq': Icons.graphic_eq,
  'album': Icons.album,
  'mood': Icons.mood,
};

/// Tile colours offered by the icon picker (ARGB).
const mixIconColors = <int>[
  0xFFE53935, 0xFFD81B60, 0xFF8E24AA, 0xFF5E35B1, 0xFF3949AB, 0xFF1E88E5,
  0xFF00897B, 0xFF43A047, 0xFFC0CA33, 0xFFFDD835, 0xFFFB8C00, 0xFF6D4C41,
  0xFF546E7A, 0xFF212121,
];

/// A mixtape's icon: the chosen symbol on its colour, else a collage of up
/// to four album covers from [artPaths] (song files), else a generic tile.
class MixIcon extends StatelessWidget {
  const MixIcon({super.key, this.spec, this.artPaths = const [], this.size = 40});

  final MixIconSpec? spec;
  final List<String> artPaths;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * 0.15);
    final icon = spec == null ? null : mixIconChoices[spec!.name];
    if (icon != null) {
      final bg = Color(spec!.color);
      final fg = ThemeData.estimateBrightnessForColor(bg) == Brightness.dark
          ? Colors.white
          : Colors.black87;
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Icon(icon, size: size * 0.6, color: fg),
      );
    }
    final paths = artPaths.take(4).toList();
    final Widget body;
    if (paths.isEmpty) {
      body = Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.queue_music, size: size * 0.6),
      );
    } else if (paths.length < 4) {
      body = TrackArt(path: paths.first, size: size);
    } else {
      final h = size / 2;
      body = Column(children: [
        Row(children: [TrackArt(path: paths[0], size: h), TrackArt(path: paths[1], size: h)]),
        Row(children: [TrackArt(path: paths[2], size: h), TrackArt(path: paths[3], size: h)]),
      ]);
    }
    return ClipRRect(borderRadius: radius, child: SizedBox(width: size, height: size, child: body));
  }
}

/// Lets the user choose a mixtape icon. Returns the new spec, or
/// [MixIconPicker.collage] for "use album art"; null if cancelled.
class MixIconPicker extends StatefulWidget {
  const MixIconPicker({super.key, this.initial, this.artPaths = const []});

  /// Sentinel result meaning "clear the icon and show album art".
  static const collage = MixIconSpec('', 0);

  final MixIconSpec? initial;
  final List<String> artPaths;

  static Future<MixIconSpec?> show(BuildContext context,
          {MixIconSpec? initial, List<String> artPaths = const []}) =>
      showDialog<MixIconSpec>(
          context: context, builder: (_) => MixIconPicker(initial: initial, artPaths: artPaths));

  @override
  State<MixIconPicker> createState() => _MixIconPickerState();
}

class _MixIconPickerState extends State<MixIconPicker> {
  late String? _name = mixIconChoices.containsKey(widget.initial?.name) ? widget.initial!.name : null;
  late int _color = widget.initial?.color ?? mixIconColors[5];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Mix icon'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: MixIcon(
                  spec: _name == null ? null : MixIconSpec(_name!, _color),
                  artPaths: widget.artPaths,
                  size: 72),
            ),
            const SizedBox(height: 12),
            ChoiceChip(
              avatar: const Icon(Icons.photo_library_outlined),
              label: const Text('Album art'),
              selected: _name == null,
              onSelected: (_) => setState(() => _name = null),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final e in mixIconChoices.entries)
                IconButton(
                  tooltip: e.key,
                  isSelected: _name == e.key,
                  style: IconButton.styleFrom(
                      backgroundColor: _name == e.key ? scheme.secondaryContainer : null),
                  icon: Icon(e.value),
                  onPressed: () => setState(() => _name = e.key),
                ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in mixIconColors)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() {
                    _color = c;
                    _name ??= mixIconChoices.keys.first;
                  }),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: c == _color && _name != null ? scheme.onSurface : Colors.transparent,
                          width: 3),
                    ),
                  ),
                ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _name == null ? MixIconPicker.collage : MixIconSpec(_name!, _color)),
          child: const Text('Use'),
        ),
      ],
    );
  }
}
