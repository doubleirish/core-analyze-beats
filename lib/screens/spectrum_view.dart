import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../services/playback_controller.dart';
import '../services/spectrum.dart';

/// Rainbow (frequency gradient) spectrum with peak-hold caps.
class SpectrumView extends StatefulWidget {
  const SpectrumView({super.key, required this.path, this.height = 120});
  final String path;
  final double height;

  @override
  State<SpectrumView> createState() => _SpectrumViewState();
}

class _SpectrumViewState extends State<SpectrumView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  SpectrumAnalyzer? _analyzer;
  bool _failed = false;
  String? _loadedPath;
  Float64List _levels = Float64List(0);
  Float64List _peaks = Float64List(0);
  Duration _last = Duration.zero;
  int _bands = 32;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
    _load();
  }

  @override
  void didUpdateWidget(SpectrumView old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  Future<void> _load() async {
    final path = widget.path;
    _loadedPath = path;
    setState(() {
      _analyzer = null;
      _failed = false;
    });
    final a = await context.read<PlaybackController>().spectrumFor(path);
    if (!mounted || _loadedPath != path) return;
    setState(() {
      _analyzer = a;
      _failed = a == null;
    });
  }

  void _tick(Duration now) {
    final a = _analyzer;
    final dt = (now - _last).inMicroseconds / 1e6;
    _last = now;
    if (a == null) return;
    final player = context.read<PlaybackController>().player;
    final target = player.playing
        ? a.bandsAt(player.position.inMilliseconds / 1000, _bands)
        : Float64List(_bands);
    if (_levels.length != _bands) {
      _levels = Float64List(_bands);
      _peaks = Float64List(_bands);
    }
    final fall = dt * 1.8; // full height in ~0.55 s
    var changed = false;
    for (var i = 0; i < _bands; i++) {
      final v = math.max(target[i], _levels[i] - fall);
      if (v != _levels[i]) changed = true;
      _levels[i] = v;
      _peaks[i] = math.max(v, _peaks[i] - dt * 0.35);
      if (_peaks[i] != v) changed = true;
    }
    if (changed) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: LayoutBuilder(builder: (context, box) {
        _bands = (box.maxWidth / 10).floor().clamp(16, 96);
        if (_analyzer == null) {
          return Center(child: Text(_failed ? 'Spectrum unavailable' : 'Loading spectrum…'));
        }
        return CustomPaint(
          painter: SpectrumPainter(Float64List.fromList(_levels), Float64List.fromList(_peaks)),
        );
      }),
    );
  }
}

class SpectrumPainter extends CustomPainter {
  SpectrumPainter(this.levels, this.peaks);
  final Float64List levels;
  final Float64List peaks;

  static Color hue(double t) => HSLColor.fromAHSL(1, 240 - 240 * t, 0.85, 0.55).toColor();

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0) return;
    final slot = size.width / n;
    final gap = math.min(2.0, slot * 0.2);
    for (var i = 0; i < n; i++) {
      final color = hue(i / math.max(1, n - 1));
      final x = i * slot + gap / 2;
      final w = slot - gap;
      final h = math.max(2.0, levels[i] * size.height);
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - h, w, h), const Radius.circular(2)),
          Paint()..color = color);
      final capY = size.height - math.max(h, peaks[i] * size.height) - 4;
      canvas.drawRect(Rect.fromLTWH(x, capY.clamp(0.0, size.height), w, 3), Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(SpectrumPainter old) => true;
}
