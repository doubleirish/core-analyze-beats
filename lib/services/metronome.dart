import 'dart:math' as math;
import 'dart:typed_data';

/// A short percussive click as a 16-bit mono WAV file.
Uint8List clickWav({int sampleRate = 44100, double seconds = 0.04, double hz = 1800, double decay = 0.008}) {
  final n = (sampleRate * seconds).round();
  final out = ByteData(44 + n * 2);
  void tag(int o, String s) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + n * 2, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, 1, Endian.little);
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  out.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = math.sin(2 * math.pi * hz * i / sampleRate) * math.exp(-i / (sampleRate * decay));
    out.setInt16(44 + i * 2, (v * 26000).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}

/// Where in the current beat we are: 0 right on a beat, approaching 1 just
/// before the next. Beats fall at `segStart + offset + k * 60 / bpm`.
double beatPhase(double pos, double segStart, double offset, double bpm) {
  final period = 60 / bpm;
  final p = (pos - segStart - offset) / period;
  final f = p - p.floorToDouble();
  return f > 1 - 1e-9 ? 0 : f;
}

/// Brightness 0..1 of the beat flash for a [phase]; peaks on the beat and decays.
double flashLevel(double phase) {
  final d = 1 - phase;
  return d * d * d;
}
