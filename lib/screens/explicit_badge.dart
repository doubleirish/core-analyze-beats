import 'package:flutter/material.dart';

/// The small boxed "E" shown on explicit songs.
class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: 'Explicit',
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2)),
        child: Text('E',
            style: TextStyle(
                fontSize: size * 0.7,
                height: 1,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.surface)),
      ),
    );
  }
}
