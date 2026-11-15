import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'http_transport.dart';
import 'importer.dart';
import 'journal.dart' show phoneJournal, phoneJournalAck, ackJson;
import 'manifest.dart';

/// Folder on the phone that USB sends land in; beats-me imports and then
/// deletes packages found here. `.nomedia` keeps other players out of it.
const phoneInbox = '/sdcard/beats-me-inbox';
const phoneInventory = '$phoneInbox/.inventory.json';
const beatsMeComponent = 'com.beatsme.beats_me/.MainActivity';
const importInboxAction = 'com.beatsme.IMPORT_INBOX';

class AdbDevice {
  AdbDevice(this.serial, this.state, [this.model]);
  final String serial, state;
  final String? model;

  bool get ready => state == 'device';
  String get label => model?.replaceAll('_', ' ') ?? serial;

  /// What to tell the user when the device isn't [ready].
  String get advice => switch (state) {
        'unauthorized' => 'Unlock the phone and tap "Allow" on the USB debugging prompt.',
        'offline' => 'The phone is offline: unplug and replug the cable.',
        'no permissions' => 'adb has no permission for this device.',
        _ => 'Phone state: $state',
      };
}

/// Parses `adb devices -l`.
List<AdbDevice> parseAdbDevices(String out) => [
      for (final line in const LineSplitter().convert(out))
        if (line.trim().isNotEmpty &&
            !line.startsWith('List of devices') &&
            !line.startsWith('*'))
          () {
            final parts = line.trim().split(RegExp(r'\s+'));
            final model = RegExp(r'model:(\S+)').firstMatch(line)?.group(1);
            final state = parts.length > 1
                ? (parts[1] == 'no' && parts.length > 2 ? 'no permissions' : parts[1])
                : 'unknown';
            return AdbDevice(parts[0], state, model);
          }()
    ];

/// `df -k <dir>` → available bytes.
int? parseDfAvailable(String out) {
  final lines = const LineSplitter().convert(out).where((l) => l.trim().isNotEmpty).toList();
  if (lines.length < 2) return null;
  final cols = lines.last.trim().split(RegExp(r'\s+'));
  if (cols.length < 4) return null;
  final kb = int.tryParse(cols[3]);
  return kb == null ? null : kb * 1024;
}

/// Song SHA-256s in the phone's inventory JSON (`adb shell cat` output):
/// the union over every mixtape, or only the entry for [key] (`label:id`).
Set<String> inventoryShas(String out, [String? key]) {
  try {
    final inv = jsonDecode(out) as Map;
    return {
      for (final e in key == null ? inv.values : [inv[key]])
        if (e is Map && e['shas'] is List)
          for (final s in e['shas'] as List) '$s'
    };
  } catch (_) {
    return {};
  }
}

class UsbResult {
  UsbResult(this.sent, this.skipped, this.bytes, this.imported);
  final int sent, skipped, bytes;

  /// True once the phone reported the import (it may still be importing).
  final bool imported;
}

/// PC side of the `usb` transport: pushes a package into the phone's inbox
/// with adb (manifest last), then starts beats-me to import it.
class UsbTransport {
  UsbTransport(this.adb, {this.run});
  final String adb;
  final Future<ProcessResult> Function(List<String> args)? run;

  /// adb from [extra], PATH, or the default Android SDK location.
  static Future<String?> findAdb([List<String> extra = const []]) async {
    final env = Platform.environment;
    final exe = Platform.isWindows ? 'adb.exe' : 'adb';
    final candidates = [
      ...extra,
      'adb',
      if (env['ANDROID_HOME'] != null) p.join(env['ANDROID_HOME']!, 'platform-tools', exe),
      if (env['ANDROID_SDK_ROOT'] != null) p.join(env['ANDROID_SDK_ROOT']!, 'platform-tools', exe),
      if (env['LOCALAPPDATA'] != null)
        p.join(env['LOCALAPPDATA']!, 'Android', 'Sdk', 'platform-tools', exe),
      if (env['HOME'] != null) p.join(env['HOME']!, 'Android', 'Sdk', 'platform-tools', exe),
    ];
    for (final c in candidates) {
      try {
        final r = await Process.run(c, ['version']);
        if (r.exitCode == 0) return c;
      } catch (_) {}
    }
    return null;
  }

  Future<ProcessResult> _run(List<String> args, {String? serial}) async {
    try {
      final command = [if (serial != null) ...['-s', serial], ...args];
      if (run case final runner?) return await runner(command);
      return await Process.run(adb, command,
          stdoutEncoding: utf8, stderrEncoding: utf8);
    } on ProcessException catch (e) {
      throw TransferException('Could not run adb: ${e.message}');
    }
  }

  Future<List<AdbDevice>> devices() async {
    final r = await _run(['devices', '-l']);
    return parseAdbDevices('${r.stdout}');
  }

  Future<int?> freeBytes(String serial) async {
    final r = await _run(['shell', 'df', '-k', '/sdcard'], serial: serial);
    return r.exitCode == 0 ? parseDfAvailable('${r.stdout}') : null;
  }

  /// SHA-256s of songs beats-me already has, in any mixtape (from the
  /// inventory it writes after each import); its importer reuses copies
  /// from other mixtapes, so none of these need sending.
  Future<Set<String>> installedShas(String serial, MixtapeManifest m) async =>
      inventoryShas(await _inventory(serial));

  Future<String> _inventory(String serial) async {
    final r = await _run(['shell', 'cat', phoneInventory], serial: serial);
    return r.exitCode == 0 ? '${r.stdout}' : '';
  }

  Future<int?> _importedAt(String serial, MixtapeManifest m) async {
    final r = await _run(['shell', 'cat', phoneInventory], serial: serial);
    try {
      final j = (jsonDecode('${r.stdout}') as Map)['${m.transport}:${m.id}'];
      return (j as Map)['createdAt'] as int?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _push(String serial, File local, String remote) async {
    final r = await _run(['push', local.path, remote], serial: serial);
    if (r.exitCode != 0) {
      throw TransferException('Copy to phone failed: ${'${r.stderr}'.trim()}${'${r.stdout}'.trim()}');
    }
  }

  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  /// Stage then rename so an open phone never imports a partial snapshot.
  /// Delivery is queued; unlike a mix, there is no import acknowledgement.
  Future<void> sendCatalog(String serial, AlbumCatalog catalog) async {
    final dir = await Directory.systemTemp.createTemp('beats-me-catalog-');
    final file = File(p.join(dir.path, albumCatalogName));
    final remote = '$phoneInbox/$albumCatalogName';
    final staging = '$remote.${DateTime.now().microsecondsSinceEpoch}.tmp';
    try {
      await file.writeAsString(catalog.encode(), flush: true);
      final mkdir = await _run(['shell', 'mkdir', '-p', phoneInbox], serial: serial);
      if (mkdir.exitCode != 0) {
        throw TransferException('Could not prepare the phone inbox: ${mkdir.stderr}');
      }
      await _push(serial, file, staging);
      final rename = await _run(['shell', 'mv', _q(staging), _q(remote)], serial: serial);
      if (rename.exitCode != 0) {
        throw TransferException('Could not finish the album list copy: ${rename.stderr}');
      }
      final launch = await _run(
          ['shell', 'am', 'start', '-a', importInboxAction, '-n', beatsMeComponent],
          serial: serial);
      if (launch.exitCode != 0) {
        throw TransferException('Album list copied, but beats-me could not be opened: ${launch.stderr}');
      }
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// The phone's play/rating journal mirror (JSONL), or null if it has none
  /// (beats-me never ran, or has no storage permission).
  Future<String?> readJournal(String serial) async {
    final r = await _run(['shell', 'cat', _q(phoneJournal)], serial: serial);
    if (r.exitCode != 0) return null;
    final out = '${r.stdout}';
    // Older adb/toybox may print the error on stdout with exit code 0.
    if (out.contains('No such file or directory')) return null;
    return out;
  }

  /// Tells beats-me the PC has imported journal entries up to [upTo]; it
  /// trims them the next time it resumes or scans its inbox.
  Future<void> ackJournal(String serial, int upTo) async {
    final tmp = File(p.join(Directory.systemTemp.path,
        'beats-me-journal-ack-${DateTime.now().microsecondsSinceEpoch}.json'));
    await tmp.writeAsString(ackJson(upTo), flush: true);
    try {
      await _push(serial, tmp, phoneJournalAck);
    } finally {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }

  Future<UsbResult> send(
    String serial,
    Directory pkg, {
    void Function(int done, int total, String what)? onProgress,
    bool Function()? cancelled,
    Duration waitForImport = const Duration(seconds: 90),
  }) async {
    final m = await MixtapeImporter.readManifest(pkg);
    final inv = await _inventory(serial);
    final have = inventoryShas(inv);
    final mine = inventoryShas(inv, '${m.transport}:${m.id}');
    final files = <String>[];
    for (final t in m.tracks) {
      if (mine.contains(t.sha256)) continue;
      // Only in another mixtape: the phone copies the song, but that copy
      // may lack art, so send the (small) art anyway.
      if (!have.contains(t.sha256) && !files.contains(t.file)) files.add(t.file);
      if (t.art != null && !files.contains(t.art)) files.add(t.art!);
    }
    files.add(playlistName);
    var total = 0;
    for (final f in files) {
      total += await File(p.join(pkg.path, f)).length();
    }

    final base = '$phoneInbox/${m.transport}/${m.id}';
    await _run(['shell', 'rm -rf ${_q(base)}'], serial: serial);
    final nomedia = File(p.join(Directory.systemTemp.path, '.nomedia'));
    if (!await nomedia.exists()) await nomedia.writeAsString('');
    await _push(serial, nomedia, '$phoneInbox/.nomedia');

    var done = 0;
    for (final rel in files) {
      if (cancelled?.call() ?? false) throw TransferException('Cancelled', TransferError.cancelled);
      onProgress?.call(done, total, p.basename(rel));
      final f = File(p.join(pkg.path, rel));
      await _push(serial, f, '$base/$rel');
      done += await f.length();
    }
    await _push(serial, File(p.join(pkg.path, manifestName)), '$base/$manifestName');
    onProgress?.call(total, total, 'Starting import on the phone');
    await _run(['shell', 'am', 'start', '-a', importInboxAction, '-n', beatsMeComponent],
        serial: serial);

    var imported = false;
    final until = DateTime.now().add(waitForImport);
    while (DateTime.now().isBefore(until)) {
      if (cancelled?.call() ?? false) break;
      if (await _importedAt(serial, m) == m.createdAt) {
        imported = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return UsbResult(files.length - 1, m.tracks.length - files.where((f) => f.startsWith('songs/')).length,
        total, imported);
  }
}
