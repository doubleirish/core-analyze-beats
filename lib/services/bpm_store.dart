import 'dart:convert';
import 'dart:io';

import '../models/tempo.dart';

/// Reads/writes the `<song>.mp3.bpm` JSON sidecar next to each mp3.
class BpmStore {
  static File sidecar(String mp3Path) => File('$mp3Path.bpm');

  /// Returns the stored results, or null if missing, corrupt, or stale
  /// (the mp3 size changed since analysis). Version 1 files load as baseline only.
  static Future<TempoResults?> load(String mp3Path) async {
    try {
      final f = sidecar(mp3Path);
      if (!await f.exists()) return null;
      final res = TempoResults.fromJson(
          jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      final mp3 = File(mp3Path);
      if (await mp3.exists()) {
        final stat = await mp3.stat();
        if (res.fileSize != stat.size) return null;
      }
      return res;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String mp3Path, TempoResults res) async {
    final stat = await File(mp3Path).stat();
    final stamped = res.stamped(stat.size, stat.modified.millisecondsSinceEpoch);
    await sidecar(mp3Path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(stamped.toJson()));
  }
}
