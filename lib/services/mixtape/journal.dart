import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'importer.dart' show SongMeta;
import 'usb_transport.dart' show phoneInbox;

/// Where the phone mirrors its journal so the PC can read it over adb.
const phoneJournal = '$phoneInbox/.journal.jsonl';

/// The PC drops this over adb after importing the journal; the phone then
/// trims entries up to `upTo` and deletes it. See [ackJson] / [parseAck].
const phoneJournalAck = '$phoneInbox/.journal-ack.json';

/// Contents of [phoneJournalAck]: `{"upTo": N, "at": ms}`.
String ackJson(int upTo, {int? at}) =>
    jsonEncode({'upTo': upTo, 'at': at ?? DateTime.now().millisecondsSinceEpoch});

/// The acknowledged seq in [phoneJournalAck] text, or null if it is
/// missing/corrupt/negative.
int? parseAck(String text) {
  try {
    final upTo = (jsonDecode(text) as Map)['upTo'];
    return upTo is num && upTo >= 0 ? upTo.toInt() : null;
  } catch (_) {
    return null;
  }
}

/// One play or rating recorded on the phone, waiting to be synced to the PC.
///
/// JSON keys: `seq`, `type` ('play' | 'rate'), `at` (ms epoch), `device`,
/// `path` (the phone copy), `origPath`, `sha256`, `title`, `artist`,
/// `duration` (s), `mixId`; plays add `listened` (s) and `done`; rates add
/// `rating` (0–5) and `fav`. Null fields are omitted.
class JournalEntry {
  const JournalEntry({
    this.seq = 0,
    required this.type,
    required this.at,
    required this.device,
    this.path,
    this.origPath,
    this.sha256,
    this.title,
    this.artist,
    this.duration,
    this.mixId,
    this.listened,
    this.done,
    this.rating,
    this.fav,
  });

  static const play = 'play';
  static const rate = 'rate';

  /// A play of [path]; [meta] is its `.meta.json` (see [SongMeta]).
  factory JournalEntry.forPlay({
    required String device,
    required double listened,
    required bool done,
    String? path,
    Map<String, dynamic>? meta,
    int? at,
  }) =>
      JournalEntry(
        type: play,
        at: at ?? DateTime.now().millisecondsSinceEpoch,
        device: device,
        path: path,
        origPath: _str(meta?['origPath']),
        sha256: _str(meta?['sha256']),
        title: _str(meta?['title']),
        artist: _str(meta?['artist']),
        duration: _num(meta?['duration']),
        mixId: _str(meta?['mixId']),
        listened: listened,
        done: done,
      );

  /// A rating/favourite change for [path]; [meta] is its `.meta.json`.
  factory JournalEntry.forRating({
    required String device,
    required int rating,
    required bool fav,
    String? path,
    Map<String, dynamic>? meta,
    int? at,
  }) =>
      JournalEntry(
        type: rate,
        at: at ?? DateTime.now().millisecondsSinceEpoch,
        device: device,
        path: path,
        origPath: _str(meta?['origPath']),
        sha256: _str(meta?['sha256']),
        title: _str(meta?['title']),
        artist: _str(meta?['artist']),
        duration: _num(meta?['duration']),
        mixId: _str(meta?['mixId']),
        rating: rating.clamp(0, 5),
        fav: fav,
      );

  /// Loads the song's `.meta.json` and builds a play entry.
  static Future<JournalEntry> playOf(String path,
      {required String device, required double listened, required bool done, int? at}) async =>
      JournalEntry.forPlay(
          device: device,
          listened: listened,
          done: done,
          path: path,
          meta: await SongMeta.load(path),
          at: at);

  /// Loads the song's `.meta.json` and builds a rating entry.
  static Future<JournalEntry> rateOf(String path,
      {required String device, required int rating, required bool fav, int? at}) async =>
      JournalEntry.forRating(
          device: device, rating: rating, fav: fav, path: path, meta: await SongMeta.load(path), at: at);

  final int seq;
  final String type;
  final int at;
  final String device;
  final String? path;
  final String? origPath;
  final String? sha256;
  final String? title;
  final String? artist;
  final double? duration;
  final String? mixId;
  final double? listened;
  final bool? done;
  final int? rating;
  final bool? fav;

  bool get isPlay => type == play;
  bool get isRate => type == rate;

  JournalEntry withSeq(int seq) => JournalEntry(
        seq: seq,
        type: type,
        at: at,
        device: device,
        path: path,
        origPath: origPath,
        sha256: sha256,
        title: title,
        artist: artist,
        duration: duration,
        mixId: mixId,
        listened: listened,
        done: done,
        rating: rating,
        fav: fav,
      );

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'type': type,
        'at': at,
        'device': device,
        if (path != null) 'path': path,
        if (origPath != null) 'origPath': origPath,
        if (sha256 != null) 'sha256': sha256,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (duration != null) 'duration': duration,
        if (mixId != null) 'mixId': mixId,
        if (listened != null) 'listened': listened,
        if (done != null) 'done': done,
        if (rating != null) 'rating': rating,
        if (fav != null) 'fav': fav,
      };

  /// Throws [FormatException] when required keys are missing or wrong.
  factory JournalEntry.fromJson(Map<String, dynamic> j) {
    final seq = j['seq'];
    final type = j['type'];
    final at = j['at'];
    if (seq is! num || type is! String || at is! num) {
      throw const FormatException('bad journal entry');
    }
    return JournalEntry(
      seq: seq.toInt(),
      type: type,
      at: at.toInt(),
      device: _str(j['device']) ?? '',
      path: _str(j['path']),
      origPath: _str(j['origPath']),
      sha256: _str(j['sha256']),
      title: _str(j['title']),
      artist: _str(j['artist']),
      duration: _num(j['duration']),
      mixId: _str(j['mixId']),
      listened: _num(j['listened']),
      done: j['done'] is bool ? j['done'] as bool : null,
      rating: _num(j['rating'])?.toInt(),
      fav: j['fav'] is bool ? j['fav'] as bool : null,
    );
  }

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
  static double? _num(Object? v) => v is num ? v.toDouble() : null;
}

/// Parses JSONL journal text (e.g. read from the phone); bad lines are skipped.
List<JournalEntry> parseJournal(String jsonl) {
  final out = <JournalEntry>[];
  for (final line in const LineSplitter().convert(jsonl)) {
    if (line.trim().isEmpty) continue;
    try {
      out.add(JournalEntry.fromJson((jsonDecode(line) as Map).cast<String, dynamic>()));
    } catch (_) {}
  }
  return out;
}

/// An append-only JSONL journal of [JournalEntry]s.
///
/// Sequence numbers start at 1 and never go back, even after [trimTo] or a
/// restart: the last one is kept in `<file>.seq`. Operations are serialized,
/// so concurrent appends within one process get unique, ordered seqs.
/// When [mirror] is given it is rewritten with the whole journal after every
/// change (errors there are ignored).
class PlayJournal {
  PlayJournal(this.file, {this.mirror});

  final File file;

  /// Can be changed later (e.g. once storage permission is granted).
  File? mirror;

  File get _seqFile => File('${file.path}.seq');

  Future<void> _lock = Future.value();
  int? _lastSeq;

  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _lock.then((_) => op());
    _lock = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<List<JournalEntry>> _read() async {
    try {
      if (!await file.exists()) return [];
      return parseJournal(await file.readAsString());
    } catch (_) {
      return [];
    }
  }

  Future<int> _loadSeq() async {
    if (_lastSeq != null) return _lastSeq!;
    var stored = 0;
    try {
      if (await _seqFile.exists()) {
        stored = int.tryParse((await _seqFile.readAsString()).trim()) ?? 0;
      }
    } catch (_) {}
    for (final e in await _read()) {
      if (e.seq > stored) stored = e.seq;
    }
    return _lastSeq = stored;
  }

  Future<void> _writeMirror() async {
    final m = mirror;
    if (m == null) return;
    try {
      final text = await file.exists() ? await file.readAsString() : '';
      await m.parent.create(recursive: true);
      await m.writeAsString(text, flush: true);
    } catch (_) {}
  }

  /// The highest seq ever assigned (0 if none).
  Future<int> get lastSeq => _serial(_loadSeq);

  /// Appends [entry] with the next seq and returns it.
  Future<JournalEntry> append(JournalEntry entry) => _serial(() async {
        final seq = await _loadSeq() + 1;
        final e = entry.withSeq(seq);
        await file.parent.create(recursive: true);
        await file.writeAsString('${jsonEncode(e.toJson())}\n', mode: FileMode.append, flush: true);
        _lastSeq = seq;
        await _seqFile.writeAsString('$seq', flush: true);
        await _writeMirror();
        return e;
      });

  /// Entries with seq greater than [seq], in order.
  Future<List<JournalEntry>> since(int seq) => _serial(() async {
        final all = await _read();
        return [for (final e in all) if (e.seq > seq) e]..sort((a, b) => a.seq.compareTo(b.seq));
      });

  /// Drops entries with seq ≤ [upTo] (after the PC acknowledged them).
  Future<void> trimTo(int upTo) => _serial(() async {
        await _loadSeq();
        final all = await _read();
        final keep = [for (final e in all) if (e.seq > upTo) e];
        if (await file.exists()) {
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsString(
              keep.map((e) => '${jsonEncode(e.toJson())}\n').join(), flush: true);
          await tmp.rename(file.path);
        }
        await _seqFile.writeAsString('$_lastSeq', flush: true);
        await _writeMirror();
      });
}
