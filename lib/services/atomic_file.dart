import 'dart:io';

/// Writes [text] to [file] through a temporary file and a rename, so a crash
/// or full disk mid-write leaves the old contents rather than half a file.
Future<void> writeStringAtomic(File file, String text) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(file.path);
}
