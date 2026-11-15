import 'package:path/path.dart' as p;

/// Track paths from M3U/M3U8 text, in order. Comments and blank lines are
/// skipped; relative entries resolve against [baseDir]; file:// URIs decode.
List<String> parseM3u(String text, {String? baseDir}) {
  final out = <String>[];
  final lines = text.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'));
  for (var line in lines) {
    line = line.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.toLowerCase().startsWith('file:')) {
      try {
        line = Uri.parse(line).toFilePath();
      } catch (_) {
        continue;
      }
    } else if (RegExp(r'^[a-z][a-z0-9+.-]+://', caseSensitive: false).hasMatch(line)) {
      continue; // streams are not local songs
    }
    if (baseDir != null && !p.isAbsolute(line)) line = p.join(baseDir, line);
    out.add(p.normalize(line));
  }
  return out;
}

class MixEntry {
  const MixEntry(this.path, this.title, {this.artist, this.durationSec});
  final String path;
  final String title;
  final String? artist;
  final double? durationSec;
}

/// Builds an extended M3U8 playlist (UTF-8, in order). Paths are absolute
/// unless [baseDir] is given, in which case songs inside it are written
/// relative to it with `/` separators. [program] adds the `#EXT-X-PROGRAM`
/// header that beats-me shows as the mix's class/program name.
String buildM3u8(List<MixEntry> items, {String? program, String? baseDir}) {
  final b = StringBuffer('#EXTM3U\n');
  if (program != null && program.trim().isNotEmpty) {
    b.write('#EXT-X-PROGRAM:${program.replaceAll(RegExp(r'[\r\n]+'), ' ').trim()}\n');
  }
  for (final e in items) {
    final secs = e.durationSec == null ? -1 : e.durationSec!.round();
    final label = [if (e.artist != null) e.artist, e.title].join(' - ').replaceAll(RegExp(r'[\r\n]+'), ' ');
    final path = baseDir != null && p.isAbsolute(e.path) && p.isWithin(baseDir, e.path)
        ? p.relative(e.path, from: baseDir).replaceAll('\\', '/')
        : e.path;
    b.write('#EXTINF:$secs,$label\n$path\n');
  }
  return b.toString();
}
