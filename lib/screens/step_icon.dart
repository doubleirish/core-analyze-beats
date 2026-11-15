import 'package:flutter/material.dart';

/// Icon for an activity or sub-activity key (see the keys the planner writes).
/// Unknown or empty keys fall back to [stepIcon] on [fallbackName].
IconData iconForKey(String? key, {String? fallbackName}) => switch (key) {
      'warmup' => Icons.wb_sunny_outlined,
      'cooldown' => Icons.ac_unit,
      'stretch' => Icons.self_improvement,
      'recovery' || 'rest' => Icons.hotel,
      'climb' => Icons.terrain,
      'sprint' => Icons.directions_run,
      'steady' => Icons.directions_bike,
      'half' => Icons.swap_horiz,
      'left' => Icons.keyboard_arrow_left,
      'right' => Icons.keyboard_arrow_right,
      'both' => Icons.unfold_more,
      'tabata' => Icons.timer,
      'work' => Icons.local_fire_department,
      'hill' => Icons.landscape,
      'resistance' => Icons.trending_up,
      'summit' => Icons.flag,
      'spin' => Icons.autorenew,
      'standsit' => Icons.accessibility_new,
      'stand' => Icons.north,
      'sit' => Icons.event_seat,
      'hover' => Icons.height,
      'pyramid' => Icons.change_history,
      'steppyramid' => Icons.stairs,
      'build' => Icons.stairs,
      'peak' => Icons.star,
      'descend' => Icons.south,
      'surge' => Icons.flash_on,
      'settle' => Icons.trending_flat,
      _ => stepIcon(fallbackName),
    };

/// Icon for a program step/part, chosen from its name (e.g. "Sprint 2").
IconData stepIcon(String? name) {
  final n = (name ?? '').toLowerCase();
  if (n.contains('warm')) return Icons.wb_sunny_outlined;
  if (n.contains('cool')) return Icons.ac_unit;
  if (n.contains('stretch')) return Icons.self_improvement;
  if (n.contains('half')) return Icons.swap_horiz;
  if (n.contains('tabata')) return Icons.timer;
  if (n.contains('pyramid')) return Icons.change_history;
  if (n.contains('hover') || n.contains('stand')) return Icons.accessibility_new;
  if (n.contains('surge')) return Icons.flash_on;
  if (n.contains('recover') || n.contains('rest') || n.contains('flat road')) return Icons.hotel;
  if (n.contains('climb') || n.contains('hill') || n.contains('strength') || n.contains('summit')) {
    return Icons.terrain;
  }
  if (n.contains('sprint')) return Icons.directions_run;
  if (n.contains('interval') ||
      n.contains('peak') ||
      n.contains('race') ||
      n.contains('jump')) {
    return Icons.bolt;
  }
  return Icons.directions_bike;
}
