import 'package:flutter/material.dart';

import '../models/step_plan.dart';
import '../models/tempo.dart';
import '../services/bar_labels.dart';
import '../services/waveform.dart';
import 'step_icon.dart';

/// Waveform seek bar; tap or drag to seek. With a step [plan] it shows the
/// song's sub-activities (name, RPM, gear) to scale; without one it shows the
/// tempo segments and their BPM.
class WaveformBar extends StatefulWidget {
  const WaveformBar({
    super.key,
    required this.wave,
    required this.map,
    required this.pos,
    required this.duration,
    required this.onSeek,
    this.plan,
    this.gearOf,
    this.height = 64,
  });

  final WaveformData? wave;
  final TempoMap? map;
  final double pos;
  final double duration;
  final ValueChanged<double> onSeek;

  /// Sub-activities of the song; null or without segments = tempo labels.
  final StepPlan? plan;

  /// The gear to show for a sub-activity, or null for none.
  final int? Function(StepSegment)? gearOf;
  final double height;

  @override
  State<WaveformBar> createState() => _WaveformBarState();
}

class _WaveformBarState extends State<WaveformBar> {
  double? _drag; // seconds while dragging

  double _at(double dx, double width) =>
      (dx / width).clamp(0.0, 1.0) * (widget.duration > 0 ? widget.duration : 1);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => widget.onSeek(_at(d.localPosition.dx, w)),
        onHorizontalDragStart: (d) => setState(() => _drag = _at(d.localPosition.dx, w)),
        onHorizontalDragUpdate: (d) => setState(() => _drag = _at(d.localPosition.dx, w)),
        onHorizontalDragEnd: (_) {
          final t = _drag;
          setState(() => _drag = null);
          if (t != null) widget.onSeek(t);
        },
        child: SizedBox(
          height: widget.height,
          width: w,
          child: CustomPaint(
            painter: _WaveformPainter(
              wave: widget.wave,
              segments: widget.map?.segments ?? const [],
              steps: widget.plan?.segments ?? const [],
              gearOf: widget.gearOf,
              pos: _drag ?? widget.pos,
              duration: widget.duration,
              played: cs.primary,
              rest: cs.outlineVariant,
              tick: cs.tertiary,
              labelColor: cs.onSurfaceVariant,
              bandColor: cs.primaryContainer,
              textColor: cs.onSurface,
            ),
          ),
        ),
      );
    });
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.wave,
    required this.segments,
    required this.pos,
    required this.duration,
    required this.played,
    required this.rest,
    required this.tick,
    required this.labelColor,
    required this.steps,
    required this.gearOf,
    required this.bandColor,
    required this.textColor,
  });

  final WaveformData? wave;
  final List<TempoSegment> segments;
  final List<StepSegment> steps;
  final int? Function(StepSegment)? gearOf;
  final double pos;
  final double duration;
  final Color played, rest, tick, labelColor, bandColor, textColor;

  bool get _stepped => steps.isNotEmpty;

  static const _iconMin = 14.0, _textMin = 30.0;

  /// The sub-activity bands behind the waveform, then their labels.
  void _paintBands(Canvas canvas, Size size, double labelH) {
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      final sx = (s.start / duration).clamp(0.0, 1.0) * size.width;
      final ex = (s.end / duration).clamp(0.0, 1.0) * size.width;
      if (ex <= sx) continue;
      // lead-in/out are dimmer; neighbours alternate a little so they can be told apart
      final a = s.lead ? 0.12 : (i.isEven ? 0.32 : 0.22);
      canvas.drawRect(Rect.fromLTRB(sx, labelH, ex, size.height),
          Paint()..color = bandColor.withValues(alpha: a));
      if (i > 0) {
        canvas.drawLine(Offset(sx, 0), Offset(sx, size.height),
            Paint()..color = textColor.withValues(alpha: 0.35)..strokeWidth = 1);
      }
    }
  }

  void _paintLabels(Canvas canvas, Size size, double labelH) {
    final style = TextStyle(fontSize: 10, color: textColor);
    for (final s in steps) {
      final sx = (s.start / duration).clamp(0.0, 1.0) * size.width;
      final ex = (s.end / duration).clamp(0.0, 1.0) * size.width;
      final room = ex - sx - 4;
      if (room < _iconMin) continue;

      final icon = iconForKey(s.icon, fallbackName: s.label);
      final ip = TextPainter(
        text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(
                fontSize: 11,
                color: textColor,
                fontFamily: icon.fontFamily,
                package: icon.fontPackage)),
        textDirection: TextDirection.ltr,
      )..layout();
      var x = sx + 2;
      if (room < _textMin) {
        ip.paint(canvas, Offset(sx + (ex - sx - ip.width) / 2, (labelH - ip.height) / 2));
        continue;
      }
      ip.paint(canvas, Offset(x, (labelH - ip.height) / 2));
      x += ip.width + 2;
      final avail = ex - x - 2;
      if (avail <= 0) continue;

      final options = labelCandidates(s, gear: gearOf?.call(s));
      if (options.isEmpty) continue;
      TextPainter? best;
      for (final text in options) {
        final tp = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: TextDirection.ltr,
            maxLines: 1)
          ..layout();
        if (tp.width <= avail) {
          best = tp;
          break;
        }
      }
      // nothing fits whole: ellipsise the plainest one rather than drop it
      best ??= TextPainter(
          text: TextSpan(text: options.last, style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
          ellipsis: '…')
        ..layout(maxWidth: avail);
      best.paint(canvas, Offset(x, (labelH - best.height) / 2));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    final labelH = _stepped ? 15.0 : 12.0;
    final mid = labelH + (size.height - labelH) / 2;
    final half = (size.height - labelH) / 2 - 1;
    final x = (pos / duration).clamp(0.0, 1.0) * size.width;
    final w = wave;
    final playedPaint = Paint()..color = played;
    final restPaint = Paint()..color = rest;
    if (_stepped) _paintBands(canvas, size, labelH);
    if (w == null || w.peaks.isEmpty) {
      canvas.drawRect(Rect.fromLTWH(0, mid - 1.5, size.width, 3), restPaint);
      canvas.drawRect(Rect.fromLTWH(0, mid - 1.5, x, 3), playedPaint);
    } else {
      const barW = 3.0;
      final n = (size.width / barW).floor();
      final per = w.peaks.length / n;
      for (var i = 0; i < n; i++) {
        final from = (i * per).floor(), to = ((i + 1) * per).ceil().clamp(from + 1, w.peaks.length);
        var m = 0;
        for (var k = from; k < to; k++) {
          if (w.peaks[k] > m) m = w.peaks[k];
        }
        final h = (m / 255 * half).clamp(1.0, half);
        final left = i * barW;
        canvas.drawRect(
            Rect.fromLTWH(left, mid - h, barW - 1, h * 2), left + barW <= x ? playedPaint : restPaint);
      }
    }

    final tickPaint = Paint()
      ..color = _stepped ? tick.withValues(alpha: 0.5) : tick
      ..strokeWidth = 1;
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      final sx = s.startSec / duration * size.width;
      if (_stepped) {
        // faint tempo-change ticks along the bottom edge only
        if (i > 0) {
          canvas.drawLine(Offset(sx, size.height - 6), Offset(sx, size.height), tickPaint);
        }
        continue;
      }
      if (i > 0) canvas.drawLine(Offset(sx, labelH), Offset(sx, size.height), tickPaint);
      final ex = s.endSec / duration * size.width;
      if (ex - sx >= 34) {
        final tp = TextPainter(
          text: TextSpan(
              text: s.bpm.toStringAsFixed(0),
              style: TextStyle(fontSize: 10, color: labelColor)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(sx + (ex - sx - tp.width) / 2, 0));
      }
    }

    canvas.drawRect(
        Rect.fromLTWH(x - 1, labelH, 2, size.height - labelH), Paint()..color = played);
    if (_stepped) _paintLabels(canvas, size, labelH);
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.pos != pos ||
      old.wave != wave ||
      old.segments != segments ||
      old.steps != steps ||
      old.duration != duration ||
      old.played != played ||
      old.bandColor != bandColor ||
      old.textColor != textColor ||
      old.labelColor != labelColor;
}
