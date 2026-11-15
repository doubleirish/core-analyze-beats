/// [bpm], or half/double it, whichever lands closest to [lo]..[hi].
double foldToBand(double bpm, double lo, double hi) {
  double dist(double v) => v < lo ? lo - v : (v > hi ? v - hi : 0);
  var best = bpm;
  for (final c in [bpm / 2, bpm * 2]) {
    if (dist(c) < dist(best)) best = c;
  }
  return best;
}

/// The cadence to ride for a song at [bpm] and how it relates to the beat.
class BeatCall {
  const BeatCall(this.rpm, this.tag);
  final double rpm;

  /// "on the beat", "½ beat", "2× beat" or "off the beat".
  final String tag;
}

BeatCall beatCall(double bpm, double lo, double hi) {
  final f = foldToBand(bpm, lo, hi);
  final inBand = f >= lo && f <= hi;
  if (!inBand) return BeatCall(bpm, 'off the beat');
  if (f == bpm) return BeatCall(f, 'on the beat');
  return BeatCall(f, f < bpm ? '½ beat' : '2× beat');
}
