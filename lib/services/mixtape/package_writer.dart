import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../mix_icon_spec.dart';
import 'manifest.dart';

class TranscodePreset {
  const TranscodePreset(this.id, this.label, this.ext, this.args);
  final String id;
  final String label;
  final String ext;
  final List<String> args;

  static const presets = [
    TranscodePreset('mp3-v2', 'MP3 VBR ~190 kbps', '.mp3', ['-c:a', 'libmp3lame', '-q:a', '2']),
    TranscodePreset('mp3-128', 'MP3 128 kbps', '.mp3', ['-c:a', 'libmp3lame', '-b:a', '128k']),
    TranscodePreset('aac-256', 'AAC 256 kbps', '.m4a', ['-c:a', 'aac', '-b:a', '256k']),
    TranscodePreset('aac-128', 'AAC 128 kbps', '.m4a', ['-c:a', 'aac', '-b:a', '128k']),
  ];

  /// Copy what Android plays, convert the rest (WMA, AIFF, APE…) to AAC.
  static const autoId = 'auto';
  static const autoTarget = 'aac-256';

  static TranscodePreset? byId(String? id) {
    for (final p in presets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// The preset to apply to [path] for the user's choice [id].
  static TranscodePreset? resolve(String? id, String path) =>
      id == autoId ? (androidPlayable(path) ? null : byId(autoTarget)) : byId(id);
}

/// A song to put in a package plus everything known about it on the PC.
class MixtapeSource {
  MixtapeSource({
    required this.path,
    this.libraryPath,
    this.title,
    this.artist,
    this.album,
    this.year,
    this.genre,
    this.trackNo,
    this.trackTotal,
    this.discNo,
    this.discTotal,
    this.duration,
    this.bpm,
    this.rating = 0,
    this.fav = false,
    this.explicit = false,
    this.tags = const [],
    this.lyrics,
    this.art,
    this.step,
    this.plan,
    this.damaged,
    this.start,
    this.end,
    this.loudness,
    this.note,
  });

  /// Trim points in seconds (null = file start / end).
  final double? start, end;

  /// Integrated loudness in LUFS.
  final double? loudness;

  /// Coaching note for this song.
  final String? note;

  final String path;

  /// Original library entry when [path] is a compatible alternative file.
  /// Phone play/rating sync must still refer to the entry used in the mix.
  final String? libraryPath;
  final String? title, artist, album, genre, lyrics;
  final int? year, trackNo, trackTotal, discNo, discTotal;
  final double? duration;
  final Map<String, dynamic>? bpm;
  final int rating;
  final bool fav, explicit;
  final List<String> tags;
  final Uint8List? art;

  /// Name of the program/class part this song was picked for, if the mix
  /// was built from a program; shown on the phone as the current/next step.
  final String? step;

  /// `StepPlan.toJson()` for this song: activity, RPM and timed sub-activities.
  final Map<String, dynamic>? plan;

  /// Why the source file looks damaged (see `quickCheckFile`); null if fine.
  final String? damaged;
}

typedef PackageProgress = void Function(int done, int total, String what);

class PackageException implements Exception {
  PackageException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Writes a self-contained, flat mixtape package into a directory.
/// Songs unchanged since the previous write (same source size/mtime/preset)
/// are reused, so repeated sends only copy what is new. The manifest is
/// written last and atomically: its presence means the package is complete.
class PackageWriter {
  PackageWriter({this.ffmpegPath = 'ffmpeg'});

  /// Null when ffmpeg is unavailable: "Auto" then copies originals (with a
  /// warning) and explicit presets fail.
  final String? ffmpegPath;

  /// Non-fatal problems from the last [write].
  final List<String> warnings = [];

  Future<MixtapeManifest> write({
    required String id,
    required String name,
    required String transport,
    required List<MixtapeSource> sources,
    required Directory out,
    String? transcodeId,
    String? sourceName,
    String? programName,
    MixIconSpec? icon,
    bool incremental = true,
    PackageProgress? onProgress,
    bool Function()? cancelled,
  }) async {
    warnings.clear();
    await out.create(recursive: true);
    await Directory(p.join(out.path, 'songs')).create(recursive: true);
    await Directory(p.join(out.path, 'art')).create(recursive: true);

    final prior = <String, MixtapeTrack>{};
    if (incremental) {
      try {
        final old = MixtapeManifest.decode(
            await File(p.join(out.path, manifestName)).readAsString());
        if (old.transport == transport) {
          for (final t in old.tracks) {
            if (t.origPath != null) prior[t.origPath!] = t;
          }
        }
      } catch (_) {}
    }

    final used = <String>{};
    final tracks = <MixtapeTrack>[];
    for (var i = 0; i < sources.length; i++) {
      if (cancelled?.call() ?? false) throw PackageException('Cancelled');
      final s = sources[i];
      final src = File(s.path);
      if (!await src.exists()) {
        throw PackageException('Missing source file: ${s.path}');
      }
      final stat = await src.stat();
      final mtime = stat.modified.millisecondsSinceEpoch;
      onProgress?.call(i, sources.length, p.basename(s.path));

      var preset = TranscodePreset.resolve(transcodeId, s.path);
      if (preset != null && ffmpegPath == null) {
        if (transcodeId != TranscodePreset.autoId) {
          throw PackageException('ffmpeg is needed to convert songs; choose "Auto" or install ffmpeg.');
        }
        warnings.add('${p.basename(s.path)} may not play on Android (ffmpeg not found to convert it)');
        preset = null;
      }

      String file;
      String sha;
      int size;
      final old = prior[s.libraryPath ?? s.path];
      if (old != null &&
          (old.srcPath ?? old.origPath) == s.path &&
          old.srcSize == stat.size &&
          old.srcMtime == mtime &&
          old.transcode == preset?.id &&
          !used.contains(old.file) &&
          await fileMatches(File(p.join(out.path, old.file)), old.size, old.sha256,
              checkHash: false)) {
        file = old.file;
        sha = old.sha256;
        size = old.size;
      } else {
        final ext = preset?.ext ?? p.extension(s.path).toLowerCase();
        file = songFileName(i, s.artist, s.title, ext);
        for (var n = 2; used.contains(file); n++) {
          file = songFileName(i, s.artist, '${s.title} ($n)', ext);
        }
        final dest = File(p.join(out.path, file));
        final tmp = File('${dest.path}.part');
        if (preset == null) {
          await src.copy(tmp.path);
        } else {
          await _transcode(src, tmp, preset);
        }
        if (await dest.exists()) await dest.delete();
        await tmp.rename(dest.path);
        sha = await sha256OfFile(dest);
        size = await dest.length();
      }
      used.add(file);

      String? art;
      if (s.art != null && s.art!.isNotEmpty) {
        final h = sha256.convert(s.art!).toString().substring(0, 16);
        final isPng = s.art!.length > 3 && s.art![0] == 0x89 && s.art![1] == 0x50;
        art = 'art/$h${isPng ? '.png' : '.jpg'}';
        final f = File(p.join(out.path, art));
        if (!await f.exists()) await f.writeAsBytes(s.art!);
      }

      tracks.add(MixtapeTrack(
        file: file,
        sha256: sha,
        size: size,
        origPath: s.libraryPath ?? s.path,
        srcPath: s.path,
        srcSize: stat.size,
        srcMtime: mtime,
        transcode: preset?.id,
        title: s.title,
        artist: s.artist,
        album: s.album,
        year: s.year,
        genre: s.genre,
        trackNo: s.trackNo,
        trackTotal: s.trackTotal,
        discNo: s.discNo,
        discTotal: s.discTotal,
        duration: s.duration,
        bpm: s.bpm,
        rating: s.rating,
        fav: s.fav,
        explicit: s.explicit,
        tags: s.tags,
        lyrics: s.lyrics,
        art: art,
        step: s.step,
        plan: s.plan,
        damaged: s.damaged,
        start: s.start,
        end: s.end,
        loudness: s.loudness,
        note: s.note,
      ));
    }

    final manifest = MixtapeManifest(
        id: id,
        name: name,
        transport: transport,
        tracks: tracks,
        sourceName: sourceName,
        programName: programName,
        icon: icon);
    await File(p.join(out.path, playlistName))
        .writeAsString(relativePlaylist(tracks, programName: programName, icon: icon));
    final tmp = File(p.join(out.path, '$manifestName.part'));
    await tmp.writeAsString(manifest.encode());
    final target = File(p.join(out.path, manifestName));
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);

    await _removeStale(out, manifest.files);
    onProgress?.call(sources.length, sources.length, 'done');
    return manifest;
  }

  Future<void> _removeStale(Directory out, Set<String> keep) async {
    for (final sub in ['songs', 'art']) {
      final d = Directory(p.join(out.path, sub));
      if (!await d.exists()) continue;
      await for (final e in d.list()) {
        if (e is! File) continue;
        if (!keep.contains('$sub/${p.basename(e.path)}')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _transcode(File src, File dest, TranscodePreset preset) async {
    final r = await Process.run(ffmpegPath!, [
      '-y',
      '-v',
      'error',
      '-i',
      src.path,
      '-vn',
      '-map_metadata',
      '0',
      ...preset.args,
      '-f',
      preset.ext == '.m4a' ? 'ipod' : 'mp3',
      dest.path,
    ], stderrEncoding: utf8);
    if (r.exitCode != 0 || !await dest.exists()) {
      throw PackageException('ffmpeg failed for ${p.basename(src.path)}: ${r.stderr}');
    }
  }

  /// Finds ffmpeg on PATH or in the bundled tools folder; null if absent.
  static Future<String?> findFfmpeg([List<String> extra = const []]) async {
    for (final c in [...extra, 'ffmpeg']) {
      try {
        final r = await Process.run(c, ['-version']);
        if (r.exitCode == 0) return c;
      } catch (_) {}
    }
    return null;
  }
}
