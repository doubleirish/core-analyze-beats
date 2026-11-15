import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../mix_icon_spec.dart';
import 'importer.dart';
import 'manifest.dart';
import 'package_writer.dart';

/// A package found on disk.
class FoundPackage {
  FoundPackage(this.dir, this.manifest);
  final Directory dir;
  final MixtapeManifest manifest;
}

/// `<root>/<label>/<mixtape-id>/` layout shared by the folder-like
/// transports; the label keeps one transport's output away from another's.
Directory labelDir(Directory root, String label, [String? id]) =>
    Directory(id == null ? p.join(root.path, label) : p.join(root.path, label, id));

/// Packages in [root] itself, its direct sub-folders, and `<root>/<label>/*`
/// for [label] (or for every label when null), so the user can pick the
/// export folder, a label folder or a single mixtape folder.
Future<List<FoundPackage>> discoverPackages(Directory root, [String? label]) async {
  final out = <FoundPackage>[];
  final seen = <String>{};
  Future<void> tryDir(Directory d) async {
    if (!seen.add(p.normalize(d.absolute.path))) return;
    try {
      final f = File(p.join(d.path, manifestName));
      if (await f.exists()) {
        final m = MixtapeManifest.decode(await f.readAsString());
        if (label == null || m.transport == label) out.add(FoundPackage(d, m));
      }
    } catch (_) {}
  }

  Future<void> children(Directory d) async {
    try {
      if (!await d.exists()) return;
      await for (final e in d.list()) {
        if (e is Directory) await tryDir(e);
      }
    } catch (_) {}
  }

  await tryDir(root);
  await children(root);
  for (final l in label == null ? Transport.all : [label]) {
    await children(labelDir(root, l));
  }
  return out;
}

Future<MixtapeManifest> _writeLabelled(
  PackageWriter writer,
  String label, {
  required String id,
  required String name,
  required List<MixtapeSource> sources,
  required Directory root,
  String? sourceName,
  String? transcodeId,
  String? programName,
  MixIconSpec? icon,
  bool incremental = true,
  PackageProgress? onProgress,
  bool Function()? cancelled,
}) =>
    writer.write(
      id: id,
      name: name,
      sourceName: sourceName,
      transport: label,
      sources: sources,
      out: labelDir(root, label, id),
      transcodeId: transcodeId,
      programName: programName,
      icon: icon,
      incremental: incremental,
      onProgress: onProgress,
      cancelled: cancelled,
    );

class FolderTransport {
  static Future<MixtapeManifest> export(
    PackageWriter writer, {
    required String id,
    required String name,
    required List<MixtapeSource> sources,
    required Directory root,
    String? sourceName,
    String? transcodeId,
    String? programName,
    MixIconSpec? icon,
    bool incremental = true,
    PackageProgress? onProgress,
    bool Function()? cancelled,
  }) =>
      _writeLabelled(writer, Transport.folder,
          id: id,
          name: name,
          sources: sources,
          root: root,
          sourceName: sourceName,
          transcodeId: transcodeId,
          programName: programName,
          icon: icon,
          incremental: incremental,
          onProgress: onProgress,
          cancelled: cancelled);
}

class ZipTransport {
  /// Builds the package in [cache] (kept between runs so unchanged songs are
  /// not copied or transcoded again) and zips it to [zipFile].
  static Future<MixtapeManifest> export(
    PackageWriter writer, {
    required String id,
    required String name,
    required List<MixtapeSource> sources,
    required File zipFile,
    required Directory cache,
    String? sourceName,
    String? transcodeId,
    String? programName,
    MixIconSpec? icon,
    bool incremental = true,
    PackageProgress? onProgress,
    bool Function()? cancelled,
  }) async {
    final dir = labelDir(cache, Transport.zip, id);
    final m = await _writeLabelled(writer, Transport.zip,
        id: id,
        name: name,
        sources: sources,
        root: cache,
        sourceName: sourceName,
        transcodeId: transcodeId,
        programName: programName,
        icon: icon,
        incremental: incremental,
        onProgress: onProgress,
        cancelled: cancelled);
    await zipFile.parent.create(recursive: true);
    final tmp = File('${zipFile.path}.part');
    final enc = ZipFileEncoder()..create(tmp.path, level: 0);
    for (final rel in [...m.files, manifestName]) {
      await enc.addFile(File(p.join(dir.path, rel)), rel, rel.endsWith('.json') ? 6 : 0);
    }
    await enc.close();
    if (await zipFile.exists()) await zipFile.delete();
    await tmp.rename(zipFile.path);
    return m;
  }

  /// Extracts [zipFile] into [staging] (cleared first), refusing entries
  /// that would land outside it. Returns the package folder.
  static Future<Directory> extract(File zipFile, Directory staging) async {
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    final input = InputFileStream(zipFile.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      if (archive.files.length > maxManifestTracks * 2 + 16) {
        throw ImportException('This mixtape has too many files.');
      }
      var total = 0;
      for (final f in archive.files) {
        if (!safeRelative(f.name.replaceAll(RegExp(r'/$'), '')) || f.isSymbolicLink) {
          throw ImportException('Unsafe entry in zip: ${f.name}');
        }
        total += f.size;
      }
      if (total > maxPackageBytes) throw ImportException('This mixtape is too large to unpack.');
      await extractArchiveToDisk(archive, staging.path);
    } on ImportException {
      rethrow;
    } catch (e) {
      throw ImportException('This file is not a readable mixtape ($e).');
    } finally {
      await input.close();
    }
    // Re-zipped by hand: the package may sit one folder down.
    if (!await File(p.join(staging.path, manifestName)).exists()) {
      final found = await discoverPackages(staging);
      if (found.length == 1) return found.single.dir;
      throw ImportException(found.isEmpty
          ? 'This file is not a beats-me mixtape (no $manifestName inside).'
          : 'This file holds ${found.length} mixtapes; send them one at a time.');
    }
    return staging;
  }

  /// Imports any mixtape zip; it is installed under its own label.
  static Future<ImportResult> import(
    File zipFile,
    Directory staging,
    MixtapeImporter importer, {
    void Function(int, int, String)? onProgress,
  }) async {
    final dir = await extract(zipFile, staging);
    try {
      return await importer.importPackage(dir, move: true, onProgress: onProgress);
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
    }
  }
}

class SyncdirTransport {
  /// Writes `<root>/syncdir/<id>/`; the manifest lands last, so a sync client
  /// or watcher never sees a half-written mixtape as complete.
  static Future<MixtapeManifest> export(
    PackageWriter writer, {
    required String id,
    required String name,
    required List<MixtapeSource> sources,
    required Directory root,
    String? sourceName,
    String? transcodeId,
    String? programName,
    MixIconSpec? icon,
    bool incremental = true,
    PackageProgress? onProgress,
    bool Function()? cancelled,
  }) =>
      _writeLabelled(writer, Transport.syncdir,
          id: id,
          name: name,
          sources: sources,
          root: root,
          sourceName: sourceName,
          transcodeId: transcodeId,
          programName: programName,
          icon: icon,
          incremental: incremental,
          onProgress: onProgress,
          cancelled: cancelled);
}

/// Polls `<root>/<label>/` and imports complete, not-yet-imported packages.
/// With [consume] (the USB inbox) packages are moved in and their folders
/// deleted afterwards; [label] null accepts every label.
class SyncdirWatcher {
  SyncdirWatcher(this.root, this.importer,
      {this.interval = const Duration(seconds: 10),
      this.label = Transport.syncdir,
      this.consume = false,
      this.onImported,
      this.onError});

  final Directory root;
  final MixtapeImporter importer;
  final Duration interval;
  final String? label;
  final bool consume;
  final void Function(ImportResult)? onImported;
  final void Function(String)? onError;
  Timer? _timer;
  bool _busy = false;
  final Map<String, DateTime> _retryAt = {};

  bool get running => _timer != null;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => scanOnce());
    scanOnce();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass; returns the imports done. Safe to call manually.
  Future<List<ImportResult>> scanOnce({bool force = false}) async {
    if (_busy) return const [];
    _busy = true;
    final done = <ImportResult>[];
    try {
      for (final f in await discoverPackages(root, label)) {
        final m = f.manifest;
        if (await importer.alreadyImported(m)) {
          if (consume) await _remove(f.dir);
          continue;
        }
        final key = '${m.transport}:${m.id}:${m.createdAt}';
        if (!force && DateTime.now().isBefore(_retryAt[key] ?? DateTime(0))) continue;
        if (!await _looksComplete(f.dir, m)) {
          _retryAt[key] = DateTime.now().add(const Duration(seconds: 30));
          continue;
        }
        try {
          final r = await importer.importPackage(f.dir, move: consume);
          if (consume && r.errors.isEmpty) await _remove(f.dir);
          done.add(r);
          onImported?.call(r);
        } catch (e) {
          _retryAt[key] = DateTime.now().add(const Duration(minutes: 2));
          onError?.call('${m.name}: $e');
        }
      }
    } finally {
      _busy = false;
    }
    return done;
  }

  Future<void> _remove(Directory d) async {
    try {
      await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Cheap size-only check so partially synced folders aren't hashed. Songs
  /// already installed may be absent (incremental USB sends skip them).
  Future<bool> _looksComplete(Directory dir, MixtapeManifest m) async {
    for (final t in m.tracks) {
      if (!safeRelative(t.file)) return false;
      final f = File(p.join(dir.path, t.file));
      if (await f.exists() && await f.length() == t.size) continue;
      if (!await importer.hasTrack(m, t, checkHash: false)) return false;
    }
    return true;
  }
}
