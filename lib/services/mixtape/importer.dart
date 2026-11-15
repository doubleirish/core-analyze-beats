import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/tempo.dart';
import '../atomic_file.dart';
import '../bpm_store.dart';
import '../m3u.dart' show parseM3u;
import 'manifest.dart';

/// Extra per-song metadata from analyze-this, stored as `<song>.meta.json`.
/// Besides the tags it links the song back to the PC: `origPath` (null when
/// unknown), `sha256`, and the mixtape's `mixId` and `transport`. Files
/// written by older versions lack those keys.
class SongMeta {
  static File sidecar(String song) => File('$song.meta.json');

  static Future<Map<String, dynamic>?> load(String song) async {
    try {
      final f = sidecar(song);
      if (!await f.exists()) return null;
      return (jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }
}

class ImportResult {
  ImportResult(this.manifest, this.paths,
      {this.copied = 0, this.reused = 0, this.reusedOther = 0, this.errors = const []});
  final MixtapeManifest manifest;

  /// Final song paths in playlist order.
  final List<String> paths;
  final int copied;
  final int reused;

  /// Songs copied from another installed mixtape instead of the package.
  final int reusedOther;
  final List<String> errors;
}

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Verifies a package directory and installs it under
/// `destRoot/<label>/<name [id]>/`, with the sidecar files beats-me already
/// understands (.bpm, art, .lrc). Packages from any transport are accepted
/// and routed by their own label, so methods never share a folder.
class MixtapeImporter {
  MixtapeImporter(this.destRoot);
  final Directory destRoot;

  File get _ledger => File(p.join(destRoot.path, '.imported.json'));

  Future<Map<String, dynamic>> _readLedger() async {
    try {
      return (jsonDecode(await _ledger.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  /// `label:id` -> {createdAt, name, dir, shas, files} for every installed
  /// mixtape. `files` (song basenames, parallel to `shas`) is missing from
  /// entries written by older versions.
  Future<Map<String, dynamic>> ledger() => _readLedger();

  /// Every installed song file with the sha256 the ledger recorded for it,
  /// and its ledger key ([mix], `label:id`), in ledger then playlist order.
  /// Entries without `files` fall back to the `.m3u8` in their folder, which
  /// lists the songs in the same order as `shas`. Missing folders and files
  /// are skipped. The sha isn't re-checked; use [fileMatches] to be sure.
  Future<List<({String mix, String sha256, File file})>> installedTracks() async {
    final out = <({String mix, String sha256, File file})>[];
    for (final MapEntry(:key, :value) in (await _readLedger()).entries) {
      if (value is! Map || value['dir'] is! String) continue;
      final dir = Directory(p.normalize(p.join(destRoot.path, value['dir'] as String)));
      if (!await dir.exists()) continue;
      final shas = [for (final s in (value['shas'] as List?) ?? const []) '$s'];
      final names = value['files'] is List
          ? [for (final f in value['files'] as List) '$f']
          : await _playlistNames(dir, value['name']);
      // An old playlist that doesn't line up with the shas can't be trusted.
      if (names == null || names.length != shas.length) continue;
      for (var i = 0; i < shas.length; i++) {
        final f = File(p.join(dir.path, p.basename(names[i])));
        if (await f.exists()) out.add((mix: key, sha256: shas[i], file: f));
      }
    }
    return out;
  }

  /// sha256 -> the first installed file with it (see [installedTracks]).
  Future<Map<String, File>> installedBySha() async {
    final out = <String, File>{};
    for (final t in await installedTracks()) {
      out.putIfAbsent(t.sha256, () => t.file);
    }
    return out;
  }

  /// Song basenames from the playlist in [dir] (preferring the one named
  /// after the mix), or null when there is none.
  Future<List<String>?> _playlistNames(Directory dir, Object? name) async {
    File? m3u;
    if (name is String) {
      final f = File(p.join(dir.path, '${sanitizeName(name)}.m3u8'));
      if (await f.exists()) m3u = f;
    }
    if (m3u == null) {
      await for (final e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.m3u8')) {
          m3u = e;
          break;
        }
      }
    }
    if (m3u == null) return null;
    try {
      return [for (final s in parseM3u(await m3u.readAsString())) p.basename(s)];
    } catch (_) {
      return null;
    }
  }

  static String _key(MixtapeManifest m) => '${m.transport}:${m.id}';

  /// True when this exact version of the mixtape was already imported.
  Future<bool> alreadyImported(MixtapeManifest m) async {
    final e = (await _readLedger())[_key(m)];
    return e is Map && e['createdAt'] == m.createdAt;
  }

  static Future<MixtapeManifest> readManifest(Directory pkg) async {
    final f = File(p.join(pkg.path, manifestName));
    if (!await f.exists()) {
      throw ImportException('Not a beats-me mixtape (no $manifestName found).');
    }
    try {
      return MixtapeManifest.decode(await f.readAsString());
    } on FormatException catch (e) {
      throw ImportException('Not a valid mixtape: ${e.message}');
    }
  }

  /// Where [m] should live now (its label folder + current name).
  Directory dirFor(MixtapeManifest m) =>
      Directory(p.normalize(p.join(destRoot.path, m.transport, installDirName(m))));

  /// Where [m] is installed today: the ledger's folder (it may still carry
  /// an old name) or [dirFor].
  Future<Directory> installedDir(MixtapeManifest m) async {
    final e = (await _readLedger())[_key(m)];
    if (e is Map && e['dir'] is String) {
      final d = Directory(p.normalize(p.join(destRoot.path, e['dir'] as String)));
      if (await d.exists()) return d;
    }
    return dirFor(m);
  }

  // sha -> installed copies, rebuilt whenever the ledger changes.
  String? _indexLedger;
  Map<String, List<({String mix, File file})>> _index = const {};

  // path -> "sha|size|mtime" of copies whose hash was already checked, so
  // verify and import don't hash the same file twice.
  final _hashed = <String, String>{};

  Future<Map<String, List<({String mix, File file})>>> _shaIndex() async {
    String raw;
    try {
      raw = await _ledger.readAsString();
    } catch (_) {
      raw = '';
    }
    if (raw != _indexLedger) {
      final idx = <String, List<({String mix, File file})>>{};
      for (final t in await installedTracks()) {
        (idx[t.sha256] ??= []).add((mix: t.mix, file: t.file));
      }
      _index = idx;
      _indexLedger = raw;
    }
    return _index;
  }

  Future<bool> _copyMatches(File f, MixtapeTrack t, bool checkHash) async {
    if (!await fileMatches(f, t.size, t.sha256, checkHash: false)) return false;
    if (!checkHash) return true;
    final stamp = '${t.sha256}|${t.size}|${(await f.lastModified()).millisecondsSinceEpoch}';
    if (_hashed[f.path] == stamp) return true;
    if (await sha256OfFile(f) != t.sha256) return false;
    _hashed[f.path] = stamp;
    return true;
  }

  static Future<File?> _artOf(File song) async {
    for (final ext in const ['.jpg', '.png']) {
      final f = File('${song.path}$ext');
      if (await f.exists()) return f;
    }
    return null;
  }

  /// A verified copy of [t] installed for a mixtape other than [m] (with a
  /// cover art sidecar when [needArt]), or null.
  Future<File?> _otherCopy(MixtapeManifest m, MixtapeTrack t,
      {bool checkHash = true, bool needArt = false}) async {
    final key = _key(m);
    for (final c in (await _shaIndex())[t.sha256] ?? const <({String mix, File file})>[]) {
      if (c.mix == key) continue;
      if (needArt && await _artOf(c.file) == null) continue;
      if (await _copyMatches(c.file, t, checkHash)) return c.file;
    }
    return null;
  }

  /// True when the song (and its cover art, if any) is already on the device,
  /// either installed for [m] or as a copy in another mixtape that the
  /// import can reuse, so a transport needn't send it again.
  Future<bool> hasTrack(MixtapeManifest m, MixtapeTrack t, {bool checkHash = true}) async {
    final dest = File(p.join((await installedDir(m)).path, p.basename(t.file)));
    if (await fileMatches(dest, t.size, t.sha256, checkHash: checkHash) &&
        (t.art == null || await _artOf(dest) != null)) {
      return true;
    }
    return await _otherCopy(m, t, checkHash: checkHash, needArt: t.art != null) != null;
  }

  /// Like [hasTrack] but ignores cover art: true when the song file itself
  /// needn't be sent (the art may still be needed).
  Future<bool> hasSong(MixtapeManifest m, MixtapeTrack t, {bool checkHash = true}) async {
    final dest = File(p.join((await installedDir(m)).path, p.basename(t.file)));
    return await fileMatches(dest, t.size, t.sha256, checkHash: checkHash) ||
        await _otherCopy(m, t, checkHash: checkHash) != null;
  }

  /// Checks that every song not already installed is present in [pkg] with
  /// the right size and hash. Returns the problems, empty when complete.
  Future<List<String>> verify(Directory pkg, MixtapeManifest m) async {
    final bad = <String>[];
    for (final t in m.tracks) {
      if (!safeRelative(t.file) || (t.art != null && !safeRelative(t.art!))) {
        bad.add('Unsafe path in manifest: ${t.file}');
        continue;
      }
      if (await hasTrack(m, t)) continue;
      if (await fileMatches(File(p.join(pkg.path, t.file)), t.size, t.sha256)) continue;
      // The song is on the device but its art only came in the package.
      if (t.art != null &&
          await File(p.join(pkg.path, t.art!)).exists() &&
          await hasSong(m, t)) {
        continue;
      }
      bad.add(t.file);
    }
    return bad;
  }

  Future<ImportResult> importPackage(
    Directory pkg, {
    bool move = false,
    void Function(int done, int total, String what)? onProgress,
  }) async {
    final m = await readManifest(pkg);
    if (!Transport.all.contains(m.transport) || !safeRelative(m.transport)) {
      throw ImportException('Unknown transfer method "${m.transport}".');
    }
    final bad = await verify(pkg, m);
    if (bad.isNotEmpty) {
      throw ImportException('Incomplete or corrupt package: ${bad.take(3).join(', ')}'
          '${bad.length > 3 ? ' (+${bad.length - 3} more)' : ''}');
    }

    // Renamed since last time: move the old folder so songs are reused.
    final dir = dirFor(m);
    final old = await installedDir(m);
    if (!p.equals(old.path, dir.path) && !await dir.exists()) {
      await dir.parent.create(recursive: true);
      try {
        await old.rename(dir.path);
      } on FileSystemException {
        // Different volume or locked: fall back to a fresh copy.
      }
    }
    await dir.create(recursive: true);
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.m3u8')) await e.delete();
    }
    final paths = <String>[];
    var copied = 0, reused = 0, reusedOther = 0;
    final errors = <String>[];
    for (var i = 0; i < m.tracks.length; i++) {
      final t = m.tracks[i];
      onProgress?.call(i, m.tracks.length, p.basename(t.file));
      try {
        var src = File(p.join(pkg.path, t.file));
        final dest = File(p.join(dir.path, p.basename(t.file)));
        final fromOld = !await src.exists() && !p.equals(old.path, dir.path);
        if (fromOld) src = File(p.join(old.path, p.basename(t.file)));
        if (await fileMatches(dest, t.size, t.sha256)) {
          reused++;
        } else if (await src.exists() ? null : await _otherCopy(m, t) case final other?) {
          // Copy, never move: the other mixtape keeps its own file.
          if (await dest.exists()) await dest.delete();
          await other.copy(dest.path);
          reusedOther++;
        } else {
          if (await dest.exists()) await dest.delete();
          if (move && !fromOld) {
            try {
              await src.rename(dest.path);
            } on FileSystemException {
              await src.copy(dest.path);
              await src.delete();
            }
          } else {
            await src.copy(dest.path);
          }
          copied++;
        }
        await _sidecars(pkg, m, t, dest, old);
        paths.add(dest.path);
      } catch (e) {
        errors.add('${t.file}: $e');
      }
    }

    final names = {for (final t in m.tracks) p.basename(t.file)};
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final b = p.basename(e.path);
      final isSong = RegExp(r'\.(mp3|m4a|aac|mp4|flac|ogg|oga|opus|wav|wma|aiff?|ape|wv|mka|amr|3gp)$',
              caseSensitive: false)
          .hasMatch(b);
      if (isSong && !names.contains(b)) await _deleteWithSidecars(e);
    }
    if (errors.isEmpty && !p.equals(old.path, dir.path) && await old.exists()) {
      try {
        await old.delete(recursive: true);
      } catch (_) {}
    }
    await File(p.join(dir.path, '${sanitizeName(m.name)}.m3u8')).writeAsString(
        relativePlaylist([
      for (final t in m.tracks)
        MixtapeTrack(
            file: p.basename(t.file),
            sha256: t.sha256,
            size: t.size,
            title: t.title,
            artist: t.artist,
            duration: t.duration,
            start: t.start,
            end: t.end)
    ], programName: m.programName, icon: m.icon));

    if (errors.isEmpty) {
      final led = await _readLedger();
      led[_key(m)] = {
        'createdAt': m.createdAt,
        'name': m.name,
        'dir': p.relative(dir.path, from: destRoot.path).replaceAll('\\', '/'),
        'shas': [for (final t in m.tracks) t.sha256],
        'files': [for (final t in m.tracks) p.basename(t.file)],
      };
      await writeStringAtomic(_ledger, jsonEncode(led));
    }
    onProgress?.call(m.tracks.length, m.tracks.length, 'done');
    return ImportResult(m, paths,
        copied: copied, reused: reused, reusedOther: reusedOther, errors: errors);
  }

  Future<void> _deleteWithSidecars(File song) async {
    for (final s in [
      song.path,
      '${song.path}.bpm',
      '${song.path}.lrc',
      '${song.path}.enrich',
      '${song.path}.jpg',
      '${song.path}.png',
      '${song.path}.meta.json',
    ]) {
      try {
        await File(s).delete();
      } catch (_) {}
    }
  }

  Future<void> _sidecars(
      Directory pkg, MixtapeManifest m, MixtapeTrack t, File dest, Directory old) async {
    final segs = (t.bpm?['segments'] as List?) ?? const [];
    if (segs.isNotEmpty) {
      final map = TempoMap(durationSec: t.duration ?? ((segs.last as Map)['end'] as num).toDouble(), segments: [
        for (final s in segs) TempoSegment.fromJson((s as Map).cast<String, dynamic>())
      ]);
      await BpmStore.save(
          dest.path, TempoResults(durationSec: map.durationSec, byAlgo: {baselineId: map}));
    }
    if (t.art != null) {
      final ext = p.extension(t.art!);
      final target = File('${dest.path}${ext == '.png' ? '.png' : '.jpg'}');
      final art = File(p.join(pkg.path, t.art!));
      final oldArt = File(p.join(old.path, p.basename(target.path)));
      if (!await target.exists()) {
        if (await art.exists()) {
          await art.copy(target.path);
        } else if (old.path != dest.parent.path && await oldArt.exists()) {
          await oldArt.copy(target.path);
        } else if (await _artOf(dest) == null) {
          final other = await _otherCopy(m, t, needArt: true);
          final otherArt = other == null ? null : await _artOf(other);
          if (otherArt != null) await otherArt.copy('${dest.path}${p.extension(otherArt.path)}');
        }
      }
    }
    if (t.lyrics != null && t.lyrics!.trim().isNotEmpty) {
      await File('${dest.path}.lrc').writeAsString(t.lyrics!);
    }
    await File('${dest.path}.enrich').writeAsString('mixtape');
    final meta = {
      'title': t.title,
      'artist': t.artist,
      'album': t.album,
      'year': t.year,
      'genre': t.genre,
      'trackNo': t.trackNo,
      'trackTotal': t.trackTotal,
      'discNo': t.discNo,
      'discTotal': t.discTotal,
      'duration': t.duration,
      'rating': t.rating,
      'fav': t.fav,
      'explicit': t.explicit,
      'tags': t.tags,
      'bpm': t.bpm == null ? null : {for (final e in t.bpm!.entries) if (e.key != 'segments') e.key: e.value},
      'step': t.step,
      'plan': t.plan,
      'damaged': ?t.damaged,
      'start': ?t.start,
      'end': ?t.end,
      'loudness': ?t.loudness,
      'note': ?t.note,
      'origPath': t.origPath,
      'sha256': t.sha256,
      'mixId': m.id,
      'transport': m.transport,
    };
    await SongMeta.sidecar(dest.path).writeAsString(jsonEncode(meta));
  }
}
