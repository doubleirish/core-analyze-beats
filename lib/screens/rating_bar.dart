import 'package:flutter/material.dart';

import '../services/playback_controller.dart';

/// Five tappable stars plus a heart. Tapping the current star again clears the rating.
class RatingStars extends StatelessWidget {
  const RatingStars({
    super.key,
    required this.rating,
    required this.fav,
    required this.onRate,
    this.onFav,
    this.size = 22,
  });
  final int rating;
  final bool fav;
  final ValueChanged<int> onRate;
  final ValueChanged<bool>? onFav;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    Widget btn(Widget icon, String tip, VoidCallback onTap) => InkResponse(
          radius: size * 0.8,
          onTap: onTap,
          child: Tooltip(
              message: tip,
              child: Padding(padding: const EdgeInsets.all(2), child: icon)),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 1; i <= 5; i++)
        btn(
          Icon(i <= rating ? Icons.star : Icons.star_border, size: size, color: color),
          i == rating ? 'Clear rating' : '$i star${i == 1 ? '' : 's'}',
          () => onRate(i == rating ? 0 : i),
        ),
      if (onFav != null) ...[
        SizedBox(width: size / 2),
        btn(
          Icon(fav ? Icons.favorite : Icons.favorite_border, size: size, color: fav ? Colors.redAccent : color),
          fav ? 'Remove favourite' : 'Favourite',
          () => onFav!(!fav),
        ),
      ],
    ]);
  }
}

/// [RatingStars] bound to a [PlaybackController]'s rating hooks for [path].
class RatingBar extends StatelessWidget {
  const RatingBar({super.key, required this.state, required this.path, this.size = 22});
  final PlaybackController state;
  final String path;
  final double size;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: RatingStars(
          rating: state.ratingOf(path),
          fav: state.favOf(path),
          size: size,
          onRate: (r) => state.setRatingFor(path, rating: r),
          onFav: (f) => state.setRatingFor(path, fav: f),
        ),
      );
}

/// Asks for a 0–5 star rating; returns null when cancelled.
Future<int?> showRatingDialog(BuildContext context, {required String title, int initial = 0}) =>
    showDialog<int>(
      context: context,
      builder: (ctx) {
        var r = initial;
        return StatefulBuilder(
          builder: (ctx, setS) => AlertDialog(
            title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
            content: RatingStars(rating: r, fav: false, size: 32, onRate: (v) => setS(() => r = v)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, r), child: const Text('Save')),
            ],
          ),
        );
      },
    );
