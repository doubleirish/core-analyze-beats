class LyricLine {
  const LyricLine(this.time, this.text);
  final double time;
  final String text;
}

class Lyrics {
  Lyrics(this.lines, {required this.synced});

  final List<LyricLine> lines;
  final bool synced;

  bool get isEmpty => lines.isEmpty;

  /// Index of the line active at [sec], or -1 before the first line.
  int indexAt(double sec) {
    if (!synced) return -1;
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= sec) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// Parses LRC text. Text without any timestamps becomes plain lyrics.
  factory Lyrics.parse(String raw) {
    final stamp = RegExp(r'\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]');
    final offsetRe = RegExp(r'^\[offset:\s*(-?\d+)\s*\]', caseSensitive: false);
    var offset = 0.0;
    final timed = <LyricLine>[];
    final plain = <LyricLine>[];
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final om = offsetRe.firstMatch(line.trim());
      if (om != null) {
        offset = int.parse(om.group(1)!) / 1000;
        continue;
      }
      final matches = stamp.allMatches(line).toList();
      if (matches.isEmpty) {
        // ignore tag lines such as [ar:Artist]
        if (RegExp(r'^\[[a-zA-Z]+:.*\]$').hasMatch(line.trim())) continue;
        plain.add(LyricLine(0, line.trim()));
        continue;
      }
      final text = line.substring(matches.last.end).trim();
      for (final m in matches) {
        final frac = m.group(3);
        final f = frac == null ? 0.0 : int.parse(frac) / _pow10(frac.length);
        timed.add(LyricLine(
            int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!) + f, text));
      }
    }
    if (timed.isNotEmpty) {
      timed.sort((a, b) => a.time.compareTo(b.time));
      return Lyrics(
          [for (final l in timed) LyricLine(l.time - offset, l.text)],
          synced: true);
    }
    while (plain.isNotEmpty && plain.first.text.isEmpty) {
      plain.removeAt(0);
    }
    return Lyrics(plain, synced: false);
  }

  static double _pow10(int n) {
    var r = 1.0;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}
