import '../../models/lyrics.dart';

String _stamp(double sec) {
  final ms = (sec * 1000).round().clamp(0, 359999999);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)}.${(ms % 1000).toString().padLeft(3, '0')}';
}

/// WebVTT captions for synchronized [lyrics], or null when they are untimed or
/// empty. Each line shows until the next one starts (at most [maxLineSec]); the
/// last line lasts [lastLineSec]. Blank lines clear the caption.
String? lyricsToVtt(Lyrics? lyrics, {double lastLineSec = 6, double maxLineSec = 12}) {
  if (lyrics == null || !lyrics.synced || lyrics.isEmpty) return null;
  final lines = lyrics.lines;
  final out = StringBuffer('WEBVTT\n\n');
  var cues = 0;
  for (var i = 0; i < lines.length; i++) {
    final text = lines[i].text.trim().replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    if (text.isEmpty) continue;
    final start = lines[i].time < 0 ? 0.0 : lines[i].time;
    var end = start + maxLineSec;
    if (i + 1 < lines.length && lines[i + 1].time > start) end = lines[i + 1].time < end ? lines[i + 1].time : end;
    if (i + 1 == lines.length) end = start + lastLineSec;
    if (end <= start) end = start + 0.5;
    out.write('${_stamp(start)} --> ${_stamp(end)}\n$text\n\n');
    cues++;
  }
  return cues == 0 ? null : out.toString();
}
