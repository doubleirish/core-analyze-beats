import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../mix_icon_spec.dart';

/// Transport labels. Every package carries the label of the transport that
/// produced it, and is installed under that label's folder on the phone, so
/// one method's output never mixes with another's.
class Transport {
  static const folder = 'folder';
  static const zip = 'zip';
  static const push = 'push';
  static const pull = 'pull';
  static const syncdir = 'syncdir';
  static const usb = 'usb';
  static const all = [push, usb, pull, zip, folder, syncdir];

  static String title(String label) => switch (label) {
        push => 'Wi-Fi (send to phone)',
        pull => 'Wi-Fi (phone downloads, QR)',
        usb => 'USB cable',
        zip => 'File (.beatsmix)',
        folder => 'Folder',
        syncdir => 'Sync folder',
        _ => label,
      };
}

/// File extension for zip-transport packages, so the phone can open them.
const mixtapeFileExt = '.beatsmix';

/// Formats Android plays out of the box.
const androidPlayableExts = {
  '.mp3', '.m4a', '.aac', '.mp4', '.flac', '.ogg', '.oga', '.opus', '.wav', '.3gp', '.amr', '.mka'
};

bool androidPlayable(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 && androidPlayableExts.contains(path.substring(dot).toLowerCase());
}

/// Random id for a new mixtape; the name is display-only.
String newMixtapeId() {
  final r = Random.secure();
  return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

const mixtapeFormat = 'beats-mixtape';
const mixtapeVersion = 1;
const manifestName = 'manifest.json';
const playlistName = 'playlist.m3u8';

/// One song in a package. [file] is relative to the package root (`songs/...`).
class MixtapeTrack {
  MixtapeTrack({
    required this.file,
    required this.sha256,
    required this.size,
    this.origPath,
    this.srcPath,
    this.srcSize,
    this.srcMtime,
    this.transcode,
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

  /// Trim points (seconds into the file); null = the file's start / end.
  final double? start, end;

  /// Integrated loudness (LUFS) measured on the PC, for even playback volume.
  final double? loudness;

  /// The instructor's coaching note for this song in this mix.
  final String? note;

  /// Seconds that play (between the trim points); null when unknown.
  double? get playSeconds {
    final d = duration;
    if (d == null) return null;
    return ((end ?? d).clamp(0.0, d) - (start ?? 0)).clamp(0.0, d);
  }

  final String file;
  final String sha256;
  final int size;

  /// Original library entry, used to match phone plays/ratings to the mix.
  final String? origPath;

  /// Physical source used for copying/transcoding (may be a compatible copy).
  /// Optional for older manifests, where [origPath] was also the source.
  final String? srcPath;
  final int? srcSize;
  final int? srcMtime;

  /// Transcode preset id used for this file, null when copied as-is.
  final String? transcode;
  final String? title, artist, album, genre, lyrics;
  final int? year, trackNo, trackTotal, discNo, discTotal;
  final double? duration;

  /// `{avg, median, min, max, stddev, segments:[{start,end,bpm}]}`.
  final Map<String, dynamic>? bpm;
  final int rating;
  final bool fav, explicit;
  final List<String> tags;

  /// Package-relative cover image (`art/<hash>.jpg`).
  final String? art;

  /// Name of the program/class part this song was picked for (e.g. "Climb"),
  /// null when the mix wasn't built from a program.
  final String? step;

  /// Timed sub-activities for this song (`StepPlan` JSON), if any.
  final Map<String, dynamic>? plan;

  /// Why the source file looks damaged (it may skip or stop); null if fine.
  /// Optional, so older apps ignore it and the manifest stays v1.
  final String? damaged;

  Map<String, dynamic> toJson() => {
        'file': file,
        'sha256': sha256,
        'size': size,
        if (origPath != null) 'origPath': origPath,
        if (srcPath != null) 'srcPath': srcPath,
        if (srcSize != null) 'srcSize': srcSize,
        if (srcMtime != null) 'srcMtime': srcMtime,
        if (transcode != null) 'transcode': transcode,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (year != null) 'year': year,
        if (genre != null) 'genre': genre,
        if (trackNo != null) 'trackNo': trackNo,
        if (trackTotal != null) 'trackTotal': trackTotal,
        if (discNo != null) 'discNo': discNo,
        if (discTotal != null) 'discTotal': discTotal,
        if (duration != null) 'duration': duration,
        if (bpm != null) 'bpm': bpm,
        'rating': rating,
        'fav': fav,
        'explicit': explicit,
        'tags': tags,
        if (lyrics != null) 'lyrics': lyrics,
        if (art != null) 'art': art,
        if (step != null) 'step': step,
        if (plan != null) 'plan': plan,
        if (damaged != null) 'damaged': damaged,
        'start': ?start,
        'end': ?end,
        'loudness': ?loudness,
        'note': ?note,
      };

  factory MixtapeTrack.fromJson(Map<String, dynamic> j) => MixtapeTrack(
        file: j['file'] as String,
        sha256: j['sha256'] as String,
        size: (j['size'] as num).toInt(),
        origPath: j['origPath'] as String?,
        srcPath: j['srcPath'] as String?,
        srcSize: (j['srcSize'] as num?)?.toInt(),
        srcMtime: (j['srcMtime'] as num?)?.toInt(),
        transcode: j['transcode'] as String?,
        title: j['title'] as String?,
        artist: j['artist'] as String?,
        album: j['album'] as String?,
        year: (j['year'] as num?)?.toInt(),
        genre: j['genre'] as String?,
        trackNo: (j['trackNo'] as num?)?.toInt(),
        trackTotal: (j['trackTotal'] as num?)?.toInt(),
        discNo: (j['discNo'] as num?)?.toInt(),
        discTotal: (j['discTotal'] as num?)?.toInt(),
        duration: (j['duration'] as num?)?.toDouble(),
        bpm: (j['bpm'] as Map?)?.cast<String, dynamic>(),
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        fav: j['fav'] == true,
        explicit: j['explicit'] == true,
        tags: [for (final t in (j['tags'] as List?) ?? const []) t as String],
        lyrics: j['lyrics'] as String?,
        art: j['art'] as String?,
        step: j['step'] as String?,
        plan: (j['plan'] as Map?)?.cast<String, dynamic>(),
        damaged: j['damaged'] as String?,
        start: (j['start'] as num?)?.toDouble(),
        end: (j['end'] as num?)?.toDouble(),
        loudness: (j['loudness'] as num?)?.toDouble(),
        note: j['note'] as String?,
      );
}

class MixtapeManifest {
  MixtapeManifest({
    required this.id,
    required this.name,
    required this.transport,
    required this.tracks,
    int? createdAt,
    this.source = 'analyze-this',
    this.sourceName,
    this.programName,
    this.icon,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  /// Stable per mix (not derived from the name), so re-sending or renaming
  /// updates the phone's copy instead of duplicating or overwriting another.
  final String id;

  /// Computer that made the package, for display.
  final String? sourceName;
  final String name;
  final String transport;
  final List<MixtapeTrack> tracks;
  final int createdAt;
  final String source;

  /// Name of the program/class this mix was built from (e.g. "Classic
  /// Program"), null when it wasn't built from a program.
  final String? programName;

  /// The mix's chosen icon; null shows a collage of its album art.
  final MixIconSpec? icon;

  /// Package-relative files the manifest refers to (songs, art, playlist).
  Set<String> get files => {
        for (final t in tracks) ...[t.file, ?t.art],
        playlistName,
      };

  Map<String, dynamic> toJson() => {
        'format': mixtapeFormat,
        'version': mixtapeVersion,
        'id': id,
        'name': name,
        'transport': transport,
        'createdAt': createdAt,
        'source': source,
        if (sourceName != null) 'sourceName': sourceName,
        if (programName != null) 'programName': programName,
        if (icon != null) 'icon': icon!.encode(),
        'tracks': [for (final t in tracks) t.toJson()],
      };

  /// Total bytes of the songs.
  int get totalBytes => tracks.fold(0, (a, t) => a + t.size);

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory MixtapeManifest.fromJson(Map<String, dynamic> j) {
    if (j['format'] != mixtapeFormat) {
      throw const FormatException('Not a beats-me mixtape manifest');
    }
    if (((j['version'] as num?) ?? 0) > mixtapeVersion) {
      throw const FormatException('Mixtape was made by a newer version');
    }
    final m = MixtapeManifest(
      id: j['id'] as String,
      name: j['name'] as String,
      transport: j['transport'] as String,
      createdAt: (j['createdAt'] as num).toInt(),
      source: (j['source'] as String?) ?? 'unknown',
      sourceName: j['sourceName'] as String?,
      programName: j['programName'] as String?,
      icon: MixIconSpec.decode(j['icon'] is String ? j['icon'] as String : null),
      tracks: [
        for (final t in j['tracks'] as List)
          MixtapeTrack.fromJson((t as Map).cast<String, dynamic>())
      ],
    );
    m.validate();
    return m;
  }

  /// Throws [FormatException] when the manifest could be harmful or is
  /// unreasonably large: ids/labels that aren't plain names, paths that could
  /// escape the package, negative or huge sizes, duplicate files, too many
  /// tracks or very long text fields. Packages come from the network, so
  /// this runs before any file work.
  void validate() {
    void check(bool ok, String what) {
      if (!ok) throw FormatException('Bad mixtape manifest: $what');
    }

    bool text(String? s, int max) => s == null || s.length <= max;
    check(isSafeId(id), 'id');
    check(Transport.all.contains(transport), 'transport');
    check(text(name, maxManifestText) && text(sourceName, maxManifestText) &&
        text(programName, maxManifestText) && text(source, maxManifestText), 'name too long');
    check(tracks.length <= maxManifestTracks, 'too many tracks');
    final seen = <String>{};
    var total = 0;
    for (final t in tracks) {
      check(safeRelative(t.file) && t.file.length <= maxManifestPath, 'path ${t.file}');
      check(seen.add(t.file), 'duplicate file ${t.file}');
      check(t.art == null || (safeRelative(t.art!) && t.art!.length <= maxManifestPath), 'art path');
      check(t.size >= 0 && t.size <= maxTrackBytes, 'size of ${t.file}');
      check(t.sha256.length <= 128, 'hash');
      check(text(t.lyrics, maxLyricsText), 'lyrics too long');
      for (final s in [t.title, t.artist, t.album, t.genre, t.origPath, t.step, t.transcode, t.damaged, t.note]) {
        check(text(s, maxManifestText), 'text too long');
      }
      check(t.tags.length <= 64 && t.tags.every((s) => s.length <= maxManifestText), 'tags');
      check(t.duration == null || (t.duration! >= 0 && t.duration! < 24 * 3600), 'duration');
      bool secs(double? v) => v == null || (v.isFinite && v >= 0 && v < 24 * 3600);
      check(secs(t.start) && secs(t.end) && (t.start == null || t.end == null || t.start! < t.end!), 'trim');
      check(t.loudness == null || (t.loudness!.isFinite && t.loudness! > -100 && t.loudness! < 20), 'loudness');
      total += t.size;
    }
    check(total <= maxPackageBytes, 'package too large');
  }

  factory MixtapeManifest.decode(String text) {
    if (text.length > maxManifestChars) {
      throw const FormatException('Bad mixtape manifest: too large');
    }
    return MixtapeManifest.fromJson((jsonDecode(text) as Map).cast<String, dynamic>());
  }
}

/// Limits for manifests received from another device.
const maxManifestTracks = 2000;
const maxManifestText = 1000;
const maxManifestPath = 400;
const maxLyricsText = 100000;
const maxManifestChars = 32 * 1024 * 1024;
const maxTrackBytes = 2 * 1024 * 1024 * 1024;
const maxPackageBytes = 64 * 1024 * 1024 * 1024;

/// Mixtape ids are plain names (letters, digits, `._-`), so they can be used
/// in paths and shell commands safely.
bool isSafeId(String id) =>
    id.isNotEmpty && id.length <= 64 && RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id) && !RegExp(r'^\.+$').hasMatch(id);

/// Characters Windows or Android file systems reject, collapsed.
String sanitizeName(String s, {int max = 80}) {
  var out = s
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (out.length > max) out = out.substring(0, max).trim();
  return out.isEmpty ? 'untitled' : out;
}

/// Flat, order-preserving song file name: `songs/003 - Artist - Title.mp3`.
String songFileName(int index, String? artist, String? title, String ext) {
  final label = [
    if (artist != null && artist.trim().isNotEmpty) artist,
    if (title != null && title.trim().isNotEmpty) title else 'track',
  ].join(' - ');
  return 'songs/${(index + 1).toString().padLeft(3, '0')} - ${sanitizeName(label, max: 110)}$ext';
}

/// Install folder for a mixtape: readable name plus a short id, so two mixes
/// whose names sanitize to the same text never share a folder.
String installDirName(MixtapeManifest m) {
  final id = sanitizeName(m.id).replaceAll(' ', '');
  return '${sanitizeName(m.name, max: 60)} [${id.length > 6 ? id.substring(0, 6) : id}]';
}

String formatBytes(int b) => b >= 1 << 30
    ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
    : b >= 1 << 20
        ? '${(b / (1 << 20)).toStringAsFixed(1)} MB'
        : '${(b / 1024).ceil()} KB';

/// Playlist comment carrying the mix's icon (see [MixIconSpec.encode]).
const mixIconTag = '#EXT-X-MIX-ICON:';

/// Extended M3U8 with package-relative paths, so it plays anywhere. When
/// [programName] is given (the program/class this mix was built from), it is
/// written as a leading comment so a device can show it without needing the
/// full manifest.
String relativePlaylist(List<MixtapeTrack> tracks, {String? programName, MixIconSpec? icon}) {
  final b = StringBuffer('#EXTM3U\n');
  if (icon != null) b.write('$mixIconTag${icon.encode()}\n');
  if (programName != null && programName.isNotEmpty) {
    b.write('#EXT-X-PROGRAM:$programName\n');
  }
  for (final t in tracks) {
    final label = [
      if (t.artist != null && t.artist!.isNotEmpty) t.artist,
      t.title ?? t.file.split('/').last
    ].join(' - ');
    b.write('#EXTINF:${t.playSeconds?.round() ?? -1},$label\n${t.file}\n');
  }
  return b.toString();
}

Future<String> sha256OfFile(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();

/// True when [f] exists with exactly the expected [size] and [sha].
Future<bool> fileMatches(File f, int size, String sha, {bool checkHash = true}) async {
  if (!await f.exists() || await f.length() != size) return false;
  return !checkHash || await sha256OfFile(f) == sha;
}

/// Rejects manifest paths that could escape the package directory.
bool safeRelative(String rel) =>
    rel.isNotEmpty &&
    !rel.startsWith('/') &&
    !rel.contains('\\') &&
    !rel.contains(':') &&
    !rel.split('/').contains('..');
