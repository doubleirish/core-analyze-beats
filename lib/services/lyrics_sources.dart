import 'dart:convert';

import 'package:http/http.dart' as http;

import 'tags.dart';

typedef Getter = Future<http.Response> Function(Uri uri, {Map<String, String>? headers});

final _stampRe = RegExp(r'\[\d+:\d{1,2}(?:[.:]\d{1,3})?\]');
bool isSyncedText(String s) => _stampRe.hasMatch(s);

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '').replaceAll(RegExp(r'[^a-z0-9\u0080-\uffff]'), '');

bool _similar(String? a, String? b) {
  if (a == null || b == null) return true;
  final x = _norm(a), y = _norm(b);
  if (x.isEmpty || y.isEmpty) return false;
  return x.contains(y) || y.contains(x);
}

String _unescape(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&#39;', "'")
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)));

dynamic _json(http.Response r) => jsonDecode(utf8.decode(r.bodyBytes));

/// A place lyrics can be fetched from. [fetch] returns LRC text, plain text or null.
abstract class LyricsSource {
  const LyricsSource();
  String get id;
  String get name;

  /// Sources that usually return timestamped lyrics are tried before plain ones.
  bool get synced;
  bool get needsToken => false;

  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token});
}

class LrclibSource extends LyricsSource {
  const LrclibSource();
  @override
  String get id => 'lrclib';
  @override
  String get name => 'LRCLIB';
  @override
  bool get synced => true;

  @override
  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token}) async {
    final title = t.title;
    if (title == null) return null;
    String? pick(Map j) {
      if (j['instrumental'] == true) return null;
      final s = j['syncedLyrics'];
      if (s is String && s.trim().isNotEmpty) return s;
      final p = j['plainLyrics'];
      return p is String && p.trim().isNotEmpty ? p : null;
    }

    if (t.artist != null) {
      final q = {
        'track_name': title,
        'artist_name': t.artist!,
        if (t.album != null) 'album_name': t.album!,
        if (durationSec != null) 'duration': durationSec.round().toString(),
      };
      final r = await get(Uri.https('lrclib.net', '/api/get', q));
      if (r.statusCode == 200) {
        final got = pick(_json(r) as Map);
        if (got != null) return got;
      }
    }
    final sq = t.artist != null ? {'track_name': title, 'artist_name': t.artist!} : {'q': title};
    final r = await get(Uri.https('lrclib.net', '/api/search', sq));
    if (r.statusCode != 200) return null;
    final list = (_json(r) as List).whereType<Map>().toList();
    Map? best;
    var bestScore = double.infinity;
    for (final m in list) {
      if (pick(m) == null) continue;
      final d = (m['duration'] as num?)?.toDouble();
      if (durationSec != null && d != null && (d - durationSec).abs() > 3) continue;
      final synced = m['syncedLyrics'] is String && (m['syncedLyrics'] as String).isNotEmpty;
      final score = (durationSec != null && d != null ? (d - durationSec).abs() : 1.5) +
          (synced ? 0 : 0.5);
      if (score < bestScore) {
        bestScore = score;
        best = m;
      }
    }
    return best == null ? null : pick(best);
  }
}

class NeteaseSource extends LyricsSource {
  const NeteaseSource();
  @override
  String get id => 'netease';
  @override
  String get name => 'NetEase';
  @override
  bool get synced => true;

  static const _headers = {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://music.163.com/'};

  @override
  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token}) async {
    final title = t.title;
    if (title == null) return null;
    final r = await get(
        Uri.https('music.163.com', '/api/search/get',
            {'s': '${t.artist ?? ''} $title'.trim(), 'type': '1', 'limit': '8'}),
        headers: _headers);
    if (r.statusCode != 200) return null;
    final songs = ((_json(r) as Map)['result']?['songs'] as List? ?? []).whereType<Map>();
    for (final s in songs) {
      if (!_similar(s['name'] as String?, title)) continue;
      final artists = (s['artists'] as List? ?? []).whereType<Map>().map((a) => a['name'] as String? ?? '');
      if (t.artist != null && artists.isNotEmpty && !artists.any((a) => _similar(a, t.artist))) {
        continue;
      }
      final ms = (s['duration'] as num?)?.toDouble();
      if (durationSec != null && ms != null && (ms / 1000 - durationSec).abs() > 4) continue;
      final lr = await get(
          Uri.https('music.163.com', '/api/song/lyric', {'id': '${s['id']}', 'lv': '1'}),
          headers: _headers);
      if (lr.statusCode != 200) continue;
      final lyric = (_json(lr) as Map)['lrc']?['lyric'];
      if (lyric is String && lyric.trim().isNotEmpty && isSyncedText(lyric)) return lyric;
    }
    return null;
  }
}

class QqSource extends LyricsSource {
  const QqSource();
  @override
  String get id => 'qq';
  @override
  String get name => 'QQ Music';
  @override
  bool get synced => true;

  static const _headers = {'User-Agent': 'Mozilla/5.0', 'Referer': 'https://y.qq.com/'};

  @override
  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token}) async {
    final title = t.title;
    if (title == null) return null;
    final r = await get(
        Uri.https('c.y.qq.com', '/soso/fcgi-bin/client_search_cp',
            {'w': '${t.artist ?? ''} $title'.trim(), 'format': 'json', 'n': '8', 'p': '1'}),
        headers: _headers);
    if (r.statusCode != 200) return null;
    final list = ((_json(r) as Map)['data']?['song']?['list'] as List? ?? []).whereType<Map>();
    for (final s in list) {
      if (!_similar(s['songname'] as String?, title)) continue;
      final singers = (s['singer'] as List? ?? []).whereType<Map>().map((a) => a['name'] as String? ?? '');
      if (t.artist != null && singers.isNotEmpty && !singers.any((a) => _similar(a, t.artist))) {
        continue;
      }
      final interval = (s['interval'] as num?)?.toDouble();
      if (durationSec != null && interval != null && (interval - durationSec).abs() > 4) continue;
      final lr = await get(
          Uri.https('c.y.qq.com', '/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
              {'songmid': '${s['songmid']}', 'format': 'json', 'nobase64': '0'}),
          headers: _headers);
      if (lr.statusCode != 200) continue;
      final b64 = (_json(lr) as Map)['lyric'];
      if (b64 is! String || b64.isEmpty) continue;
      final text = _unescape(utf8.decode(base64.decode(b64)));
      if (isSyncedText(text)) return text;
    }
    return null;
  }
}

class MegalobizSource extends LyricsSource {
  const MegalobizSource();
  @override
  String get id => 'megalobiz';
  @override
  String get name => 'Megalobiz';
  @override
  bool get synced => true;

  @override
  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token}) async {
    final title = t.title;
    if (title == null) return null;
    final q = {
      'title': title,
      if (t.artist != null) 'artist': t.artist!,
      if (durationSec != null) 'duration': durationSec.round().toString(),
      'limit': '5',
    };
    final r = await get(Uri.https('api.megalobiz.com', '/api/public/v1/search', q));
    if (r.statusCode != 200) return null;
    final results = ((_json(r) as Map)['results'] as List? ?? []).whereType<Map>();
    for (final m in results) {
      if (!_similar(m['title'] as String?, title) || !_similar(m['artist'] as String?, t.artist)) {
        continue;
      }
      final diff = (m['duration_diff'] as num?)?.toDouble();
      if (durationSec != null && diff != null && diff > 3) continue;
      final url = m['lrc_url'] as String?;
      if (url == null) continue;
      final lr = await get(Uri.parse(url));
      if (lr.statusCode != 200) continue;
      final text = utf8.decode(lr.bodyBytes);
      if (isSyncedText(text)) return text;
    }
    return null;
  }
}

class LyricsOvhSource extends LyricsSource {
  const LyricsOvhSource();
  @override
  String get id => 'ovh';
  @override
  String get name => 'lyrics.ovh';
  @override
  bool get synced => false;

  @override
  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token}) async {
    final title = t.title, artist = t.artist;
    if (title == null || artist == null) return null;
    final r = await get(Uri.https('api.lyrics.ovh', '/v1/$artist/$title'));
    if (r.statusCode != 200) return null;
    final text = (_json(r) as Map)['lyrics'];
    return text is String && text.trim().isNotEmpty ? text.replaceAll('\r\n', '\n').trim() : null;
  }
}

class ChartLyricsSource extends LyricsSource {
  const ChartLyricsSource();
  @override
  String get id => 'chartlyrics';
  @override
  String get name => 'ChartLyrics';
  @override
  bool get synced => false;

  @override
  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token}) async {
    final title = t.title, artist = t.artist;
    if (title == null || artist == null) return null;
    final r = await get(Uri.http('api.chartlyrics.com', '/apiv1.asmx/SearchLyricDirect',
        {'artist': artist, 'song': title}));
    if (r.statusCode != 200) return null;
    final m = RegExp(r'<Lyric>([\s\S]*?)</Lyric>').firstMatch(utf8.decode(r.bodyBytes));
    final text = m == null ? '' : _unescape(m[1]!).replaceAll('\r\n', '\n').trim();
    return text.isEmpty ? null : text;
  }
}

class GeniusSource extends LyricsSource {
  const GeniusSource();
  @override
  String get id => 'genius';
  @override
  String get name => 'Genius';
  @override
  bool get synced => false;
  @override
  bool get needsToken => true;

  @override
  Future<String?> fetch(TrackTags t, double? durationSec, Getter get, {String? token}) async {
    final title = t.title;
    if (title == null || token == null || token.isEmpty) return null;
    final r = await get(
        Uri.https('api.genius.com', '/search', {'q': '${t.artist ?? ''} $title'.trim()}),
        headers: {'Authorization': 'Bearer $token'});
    if (r.statusCode != 200) return null;
    final hits = ((_json(r) as Map)['response']?['hits'] as List? ?? []).whereType<Map>();
    for (final h in hits) {
      final res = h['result'];
      if (res is! Map) continue;
      if (!_similar(res['title'] as String?, title)) continue;
      if (!_similar(res['primary_artist']?['name'] as String?, t.artist)) continue;
      final url = res['url'] as String?;
      if (url == null) continue;
      final page = await get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'});
      if (page.statusCode != 200) continue;
      final text = parseGeniusPage(utf8.decode(page.bodyBytes));
      if (text != null) return text;
    }
    return null;
  }
}

/// Extracts lyrics text from Genius lyrics containers.
String? parseGeniusPage(String html) {
  final parts = RegExp(r'<div[^>]*data-lyrics-container="true"[^>]*>([\s\S]*?)</div>')
      .allMatches(html)
      .map((m) => m[1]!)
      .toList();
  if (parts.isEmpty) return null;
  final text = _unescape(parts
          .join('\n')
          .replaceAll(RegExp(r'<br\s*/?>'), '\n')
          .replaceAll(RegExp(r'<[^>]+>'), ''))
      .trim();
  return text.isEmpty ? null : text;
}

const allLyricsSources = <LyricsSource>[
  LrclibSource(),
  NeteaseSource(),
  QqSource(),
  MegalobizSource(),
  LyricsOvhSource(),
  ChartLyricsSource(),
  GeniusSource(),
];
