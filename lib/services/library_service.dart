import 'dart:io';

import 'container_tags.dart';

/// Lists supported audio files (mp3, m4a, wma) in a folder and all its
/// subfolders, sorted by path. (Name kept from when only mp3 was supported.)
Future<List<String>> scanMp3s(String dir) async {
  final out = <String>[];
  final pending = <Directory>[Directory(dir)];
  var first = true;
  while (pending.isNotEmpty) {
    final d = pending.removeLast();
    try {
      await for (final e in d.list(followLinks: false)) {
        if (e is Directory) {
          pending.add(e);
        } else if (e is File && isAudioPath(e.path)) {
          out.add(e.path);
        }
      }
    } catch (_) {
      if (first) rethrow; // root unreadable is an error; subdirs are skipped
    }
    first = false;
  }
  out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
}

/// Path relative to [root], for display.
String relativeName(String path, String? root) {
  if (root == null) return baseName(path);
  final r = root.endsWith('\\') || root.endsWith('/') ? root : '$root${Platform.pathSeparator}';
  return path.startsWith(r) ? path.substring(r.length) : baseName(path);
}

String baseName(String path) => path.split(RegExp(r'[\\/]')).last;

String fmtTime(double sec) {
  final s = sec.isNegative ? 0 : sec.round();
  final m = s ~/ 60;
  return '$m:${(s % 60).toString().padLeft(2, '0')}';
}
