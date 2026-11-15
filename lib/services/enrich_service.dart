import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'net.dart';

import '../models/lyrics.dart';
import 'container_tags.dart';
import 'lyrics_sources.dart';
import 'tags.dart';

const _userAgent = 'beats-me/1.0 (personal music player)';

class LyricsHit {
  LyricsHit(this.text, this.sourceId, this.sourceName, this.synced);
  final String text;
  final String sourceId;
  final String sourceName;
  final bool synced;
}

class EnrichResult {
  EnrichResult({this.lyricsSaved = false, this.artSaved = false, this.notes = const []});
  final bool lyricsSaved;
  final bool artSaved;
  final List<String> notes;
}

/// Finds and fetches album art and lyrics, saving them next to the mp3.
class EnrichService {
  EnrichService({
    http.Client? client,
    this.minGap = const Duration(milliseconds: 1100),
    PoliteHttp? net,
    List<LyricsSource>? lyricsSources,
  }) : net = net ?? PoliteHttp(client: client, gaps: {'musicbrainz': minGap}),
       _sources = lyricsSources ?? allLyricsSources;

  final PoliteHttp net;
  final List<LyricsSource> _sources;
  final Duration minGap;
  Set<String> disabledSources = {};
  String? geniusToken;

  static const _coverNames = ['cover', 'folder', 'front', 'album'];
  static const _imgExts = ['jpg', 'jpeg', 'png'];

  static File lyricsFile(String mp3) => File('$mp3.lrc');
  static File markerFile(String mp3) => File('$mp3.enrich');

  // ---- local discovery ----

  static String _stem(String mp3) {
    final dot = mp3.lastIndexOf('.');
    return isAudioPath(mp3) && dot > 0 ? mp3.substring(0, dot) : mp3;
  }

  static Future<Lyrics?> localLyrics(String mp3, {String? embedded}) async {
    for (final f in [lyricsFile(mp3), File('${_stem(mp3)}.lrc')]) {
      try {
        if (await f.exists()) {
          final l = Lyrics.parse(await f.readAsString());
          if (!l.isEmpty) return l;
        }
      } catch (_) {}
    }
    if (embedded != null) {
      final l = Lyrics.parse(embedded);
      if (!l.isEmpty) return l;
    }
    return null;
  }

  /// Art file for the song: per-song image, else a folder cover whose album matches.
  static Future<File?> localArt(String mp3, {String? album}) async {
    for (final e in _imgExts) {
      final f = File('$mp3.$e');
      if (await f.exists()) return f;
    }
    final dir = File(mp3).parent.path;
    for (final n in _coverNames) {
      for (final e in _imgExts) {
        final f = File('$dir${Platform.pathSeparator}$n.$e');
        if (!await f.exists()) continue;
        final meta = File('${f.path}.json');
        if (await meta.exists()) {
          try {
            final saved = (jsonDecode(await meta.readAsString()) as Map)['album'] as String?;
            if (saved != null && album != null && saved.toLowerCase() != album.toLowerCase()) {
              continue;
            }
          } catch (_) {}
        }
        return f;
      }
    }
    return null;
  }

  // ---- online ----

  Future<http.Response> _get(Uri uri, {Duration? gap, Map<String, String>? headers}) =>
      net.get(uri, headers: {'User-Agent': _userAgent, ...?headers});

  /// Tries every enabled source: timestamped sources first (first synced hit
  /// wins), then plain-text sources. A plain result from a synced source is
  /// kept as a fallback while the other synced sources are tried.
  /// Throws only if nothing was found and every source that ran failed.
  Future<LyricsHit?> fetchLyricsHit(TrackTags t, {double? durationSec, bool quick = false}) async {
    final enabled = _sources
        .where(
          (s) =>
              !disabledSources.contains(s.id) &&
              (_fails[s.id] ?? 0) < maxSourceFailures &&
              (!quick || quickLyricsSources.contains(s.id)),
        )
        .toList();
    enabled.sort((a, b) {
      if (a.synced != b.synced) return a.synced ? -1 : 1;
      double rate(LyricsSource s) => ((_hits[s.id] ?? 0) + 1) / ((_attempts[s.id] ?? 0) + 2);
      final byRate = rate(b).compareTo(rate(a));
      return byRate != 0 ? byRate : _sources.indexOf(a).compareTo(_sources.indexOf(b));
    });
    LyricsHit? plain;
    var ran = 0, failed = 0;
    Object? firstError;
    for (final src in enabled) {
      if ((_fails[src.id] ?? 0) >= maxSourceFailures) continue;
      if (plain != null && !src.synced) break;
      if (src.needsToken && (geniusToken == null || geniusToken!.isEmpty)) continue;
      ran++;
      _attempts[src.id] = (_attempts[src.id] ?? 0) + 1;
      try {
        final text = await src.fetch(t, durationSec, _get, token: geniusToken);
        _fails[src.id] = 0;
        if (text == null || text.trim().isEmpty) continue;
        _hits[src.id] = (_hits[src.id] ?? 0) + 1;
        if (isSyncedText(text)) return LyricsHit(text, src.id, src.name, true);
        plain ??= LyricsHit(text, src.id, src.name, false);
      } catch (e) {
        failed++;
        _fails[src.id] = (_fails[src.id] ?? 0) + 1;
        firstError ??= e;
      }
    }
    if (plain != null) return plain;
    if (ran > 0 && failed == ran) throw firstError!;
    // a miss that skipped dead sources isn't definitive: leave it to retry
    if (_sources.any(
      (s) =>
          (_fails[s.id] ?? 0) >= maxSourceFailures &&
          !disabledSources.contains(s.id) &&
          (!quick || quickLyricsSources.contains(s.id)),
    )) {
      throw const HttpException('some lyrics sources are unavailable');
    }
    return null;
  }

  /// Sources that error or time out this many times in a row are skipped until
  /// [resetSourceFailures], so one dead host can't stall a whole scan.
  static const maxSourceFailures = 5;
  final Map<String, int> _fails = {};
  final Map<String, int> _attempts = {};
  final Map<String, int> _hits = {};
  void resetSourceFailures() {
    _fails.clear();
    _attempts.clear();
    _hits.clear();
  }

  /// The fast, high-yield sources used by quick lyrics lookups.
  static const quickLyricsSources = {'lrclib', 'netease'};

  Future<String?> fetchLyrics(TrackTags t, {double? durationSec}) async =>
      (await fetchLyricsHit(t, durationSec: durationSec))?.text;

  /// Cover art bytes from iTunes, then MusicBrainz / Cover Art Archive, then Deezer.
  Future<Uint8List?> fetchArt(TrackTags t) async {
    final title = t.title;
    if (title == null) return null;
    try {
      final term = [if (t.artist != null) t.artist!, if (t.album != null) t.album! else title].join(' ');
      final r = await _get(
        Uri.https('itunes.apple.com', '/search', {
          'term': term,
          'entity': t.album != null ? 'album' : 'song',
          'limit': '5',
        }),
      );
      if (r.statusCode == 200) {
        final results = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['results'] as List? ?? []).whereType<Map>();
        for (final m in results) {
          final a = (m['artistName'] as String?)?.toLowerCase();
          if (t.artist != null &&
              a != null &&
              !a.contains(t.artist!.toLowerCase()) &&
              !t.artist!.toLowerCase().contains(a)) {
            continue;
          }
          final url = m['artworkUrl100'] as String?;
          if (url == null) continue;
          final img = await _get(Uri.parse(url.replaceFirst('100x100bb', '1000x1000bb')));
          if (img.statusCode == 200 && img.bodyBytes.length > 1000) return img.bodyBytes;
        }
      }
    } catch (_) {}
    try {
      final release = t.album ?? title;
      final q = 'release:"$release"${t.artist != null ? ' AND artist:"${t.artist}"' : ''}';
      final r = await _get(Uri.https('musicbrainz.org', '/ws/2/release/', {'query': q, 'fmt': 'json', 'limit': '3'}));
      if (r.statusCode == 200) {
        final rels = ((jsonDecode(utf8.decode(r.bodyBytes)) as Map)['releases'] as List? ?? []).whereType<Map>();
        for (final m in rels) {
          final img = await _get(Uri.parse('https://coverartarchive.org/release/${m['id']}/front-500'));
          if (img.statusCode == 200 && img.bodyBytes.length > 1000) return img.bodyBytes;
        }
      }
    } catch (_) {}
    try {
      final q = [if (t.artist != null) t.artist!, t.album ?? title].join(' ');
      final r = await _get(Uri.https('api.deezer.com', '/search/album', {'q': q, 'limit': '5'}));
      if (r.statusCode == 200) {
        final data = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['data'] as List? ?? [];
        for (final m in data.whereType<Map>()) {
          final a = ((m['artist'] as Map?)?['name'] as String?)?.toLowerCase();
          if (t.artist != null &&
              a != null &&
              !a.contains(t.artist!.toLowerCase()) &&
              !t.artist!.toLowerCase().contains(a)) {
            continue;
          }
          final url = (m['cover_xl'] ?? m['cover_big']) as String?;
          final host = url == null ? null : Uri.tryParse(url)?.host;
          if (url == null || host == null || !(host == 'dzcdn.net' || host.endsWith('.dzcdn.net'))) continue;
          final img = await _get(Uri.parse(url));
          if (img.statusCode == 200 && img.bodyBytes.length > 1000) return img.bodyBytes;
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _looksPng(Uint8List b) => b.length > 4 && b[0] == 0x89 && b[1] == 0x50;

  /// Downloads cover art for [mp3] only (no lyrics) and writes it next to the
  /// file. Returns true when new art was saved; false when none was found or
  /// the song already has art. Throws on network failure.
  Future<bool> fetchArtOnly(String mp3) async {
    final tags = await readTags(mp3);
    if (tags.picture != null || await localArt(mp3, album: tags.album) != null) return false;
    final bytes = await fetchArt(tags);
    if (bytes == null) return false;
    final ext = _looksPng(bytes) ? 'png' : 'jpg';
    final dir = File(mp3).parent.path;
    final shared = File('$dir${Platform.pathSeparator}cover.$ext');
    final canShare = tags.album != null && !await shared.exists();
    final target = canShare ? shared : File('$mp3.$ext');
    await target.writeAsBytes(bytes);
    if (canShare) {
      await File('${shared.path}.json').writeAsString(jsonEncode({'album': tags.album, 'artist': tags.artist}));
    }
    return true;
  }

  /// Fetches whatever is missing for [mp3] and writes it next to the file.
  /// Songs already attempted (marker file) are skipped unless [force].
  Future<EnrichResult> enrich(String mp3, {double? durationSec, bool force = false}) async {
    final marker = markerFile(mp3);
    if (!force && await marker.exists()) {
      return EnrichResult(notes: ['already attempted']);
    }
    final tags = await readTags(mp3);
    final notes = <String>[];
    var lyricsSaved = false, artSaved = false;
    String? lyricsSource;

    if (await localLyrics(mp3, embedded: tags.lyrics) == null) {
      try {
        final hit = await fetchLyricsHit(tags, durationSec: durationSec);
        if (hit != null) {
          await lyricsFile(mp3).writeAsString(hit.text);
          lyricsSaved = true;
          lyricsSource = hit.sourceName;
          notes.add('lyrics from ${hit.sourceName}${hit.synced ? '' : ' (not synced)'}');
        } else {
          notes.add('no lyrics found');
        }
      } catch (e) {
        notes.add('lyrics lookup failed: $e');
      }
    }

    if (tags.picture == null && await localArt(mp3, album: tags.album) == null) {
      try {
        final bytes = await fetchArt(tags);
        if (bytes != null) {
          final ext = _looksPng(bytes) ? 'png' : 'jpg';
          final dir = File(mp3).parent.path;
          final shared = File('$dir${Platform.pathSeparator}cover.$ext');
          final canShare = tags.album != null && !await shared.exists();
          final target = canShare ? shared : File('$mp3.$ext');
          await target.writeAsBytes(bytes);
          if (canShare) {
            await File('${shared.path}.json').writeAsString(jsonEncode({'album': tags.album, 'artist': tags.artist}));
          }
          artSaved = true;
        } else {
          notes.add('no art found');
        }
      } catch (e) {
        notes.add('art lookup failed: $e');
      }
    }

    final failed = notes.any((n) => n.contains('failed'));
    if (!failed) {
      // only remember definitive answers; network failures should be retried
      await marker.writeAsString(
        jsonEncode({
          'tried': DateTime.now().toIso8601String(),
          'lyrics': lyricsSaved,
          'lyricsSource': lyricsSource,
          'art': artSaved,
        }),
      );
    }
    return EnrichResult(lyricsSaved: lyricsSaved, artSaved: artSaved, notes: notes);
  }
}
