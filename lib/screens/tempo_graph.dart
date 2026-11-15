import 'package:flutter/material.dart';

import '../models/tempo.dart';

class TempoGraph extends StatelessWidget {
  const TempoGraph({super.key, required this.map, this.playhead, this.height = 130});
  final TempoMap map;
  final double? playhead;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _TempoPainter(map, theme.colorScheme.primary, theme.colorScheme.onSurface,
            theme.colorScheme.tertiary, playhead),
      ),
    );
  }
}

class _TempoPainter extends CustomPainter {
  _TempoPainter(this.tm, this.color, this.textColor, this.headColor, this.playhead);
  final TempoMap tm;
  final Color color;
  final Color textColor;
  final Color headColor;
  final double? playhead;

  @override
  void paint(Canvas canvas, Size size) {
    if (tm.segments.isEmpty || tm.durationSec <= 0) return;
    final bpms = tm.segments.map((e) => e.bpm);
    final lo = bpms.reduce((a, b) => a < b ? a : b) - 10;
    final hi = bpms.reduce((a, b) => a > b ? a : b) + 10;
    final paint = Paint()..color = color.withValues(alpha: 0.8);
    const labelRoom = 16.0;
    final chartH = size.height - labelRoom;
    for (final seg in tm.segments) {
      final x0 = seg.startSec / tm.durationSec * size.width;
      final x1 = seg.endSec / tm.durationSec * size.width;
      final h = (seg.bpm - lo) / (hi - lo) * chartH;
      final top = size.height - h;
      canvas.drawRect(Rect.fromLTRB(x0, top, x1 - 1, size.height), paint);
      final tp = TextPainter(
        text: TextSpan(
            text: seg.bpm.round().toString(),
            style: TextStyle(color: textColor, fontSize: 12)),
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width + 4 <= x1 - x0) {
        tp.paint(canvas, Offset((x0 + x1 - tp.width) / 2, top - tp.height - 1));
      }
    }
    final p = playhead;
    if (p != null) {
      final x = (p / tm.durationSec).clamp(0.0, 1.0) * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height),
          Paint()..color = headColor..strokeWidth = 2);
    }
  }

  @override
  bool shouldRepaint(_TempoPainter old) =>
      old.tm != tm || old.playhead != playhead || old.color != color;
}
