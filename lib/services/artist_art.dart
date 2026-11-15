import 'dart:convert';
import 'dart:io';

import 'net.dart';

/// Only HTTPS images from Deezer's own hosts are fetched.
bool isDeezerImageUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'https') return false;
  final h = u.host.toLowerCase();
  return h == 'dzcdn.net' || h.endsWith('.dzcdn.net') || h == 'deezer.com' || h.endsWith('.deezer.com');
}

/// Only HTTPS images from the hosts of the photo sources are fetched.
bool isTrustedImageUrl(String url) {
  if (isDeezerImageUrl(url)) return true;
  final u = Uri.tryParse(url);
  if (u == null || u.scheme != 'https') return false;
  final h = u.host.toLowerCase();
  const hosts = ['theaudiodb.com', 'wikimedia.org', 'mzstatic.com'];
  return hosts.any((d) => h == d || h.endsWith('.$d'));
}

/// Loose artist-name comparison key: ignores case, accents, punctuation, a
/// leading "The", "&" vs "and" and a trailing "feat." credit.
String looseArtistKey(String artist) {
  var s = artist.toLowerCase();
  const from = 'àáâãäåçèéêëìíîïñòóôõöøùúûüýÿ';
  const to = 'aaaaaaceeeeiiiinoooooouuuuyy';
  s = s.split('').map((ch) {
    final i = from.indexOf(ch);
    return i < 0 ? ch : to[i];
  }).join();
  s = s.replaceAll(RegExp(r'\s+(feat\.?|ft\.?|featuring)\s.*$'), '');
  s = s.replaceAll('&', ' and ').replaceFirst(RegExp(r'^\s*the\s+'), '');
  return s.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

/// JPEG, PNG, GIF or WebP by magic number.
bool looksLikeImage(List<int> b) =>
    b.length > 12 &&
    ((b[0] == 0xFF && b[1] == 0xD8) ||
        (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) ||
        (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) ||
        (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45));

/// Looks up artist photos and keeps them on disk. Deezer is tried first, then
/// TheAudioDB, MusicBrainz -> Wikidata -> Commons, Wikipedia and finally the
/// artist's iTunes album art.
///
/// Misses are remembered (a versioned ".none" marker) so an artist is only
/// looked up once; a network failure in any source is not remembered, so it is
/// retried next time. Markers from before the extra sources existed are retried.
class ArtistArt {
  ArtistArt(this.dir, {PoliteHttp? net}) : net = net ?? PoliteHttp();

  final Directory dir;
  final PoliteHttp net;
  final Map<String, Future<File?>> _pending = {};

  static String keyFor(String artist) =>
      artist.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

  File _file(String artist) => File('${dir.path}${Platform.pathSeparator}${keyFor(artist)}.jpg');
  File _none(String artist) => File('${dir.path}${Platform.pathSeparator}${keyFor(artist)}.none');

  /// The cached photo if there is one; never touches the network.
  Future<File?> cached(String artist) async {
    final f = _file(artist);
    return await f.exists() ? f : null;
  }

  Future<void> waitForFetch(String artist) async {
    await _pending[artist.toLowerCase().trim()];
  }

  /// Every matching photo URL from all sources. Throws only when Deezer fails.
  Future<List<String>> candidates(String artist) async {
    final res = await net.get(
        Uri.https('api.deezer.com', '/search/artist', {'q': artist, 'limit': '25'}));
    if (res.statusCode != 200) {
      throw HttpException('Artist photo search failed (${res.statusCode})');
    }
    final urls = pictureCandidates(jsonDecode(res.body), artist);
    for (final source in _fallbackSources(artist)) {
      try {
        for (final u in await source()) {
          if (!urls.contains(u)) urls.add(u);
        }
      } catch (_) {}
    }
    return urls;
  }

  Future<File> setFromBytes(String artist, List<int> bytes) async {
    if (keyFor(artist).isEmpty) throw ArgumentError.value(artist, 'artist');
    if (!looksLikeImage(bytes)) throw const FormatException('Not a supported image');
    await dir.create(recursive: true);
    final f = _file(artist);
    final temporary = File('${f.path}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(f.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    final none = _none(artist);
    if (await none.exists()) await none.delete();
    return f;
  }

  Future<List<int>> imageBytes(String url) async {
    if (!isTrustedImageUrl(url)) throw ArgumentError.value(url, 'url');
    final res = await net.get(Uri.parse(url));
    if (res.statusCode != 200) {
      throw HttpException('Artist photo download failed (${res.statusCode})');
    }
    if (!looksLikeImage(res.bodyBytes)) {
      throw const FormatException('Artist photo download is not an image');
    }
    return res.bodyBytes;
  }

  Future<File> setFromUrl(String artist, String url) async =>
      setFromBytes(artist, await imageBytes(url));

  Future<void> clear(String artist) async {
    for (final f in [_file(artist), _none(artist)]) {
      if (await f.exists()) await f.delete();
    }
  }

  /// Cached photo, else downloads it. Null when no source has one (or one is unreachable).
  /// [force] retries an artist previously remembered as a miss.
  Future<File?> fetch(String artist, {bool force = false}) async {
    if (keyFor(artist).isEmpty) return null;
    if (force && await _none(artist).exists()) await _none(artist).delete();
    return _fetchShared(artist);
  }

  Future<File?> _fetchShared(String artist) {
    return _pending.putIfAbsent(artist.toLowerCase().trim(), () async {
      try {
        return await _fetch(artist);
      } finally {
        _pending.remove(artist.toLowerCase().trim());
      }
    });
  }

  Future<File?> _fetch(String artist) async {
    final f = _file(artist);
    if (await f.exists()) return f;
    final none = _none(artist);
    if (await none.exists() && await none.readAsString() == _markerVersion) return null;
    var failed = false;
    final sources = <Future<List<String>> Function()>[
      () async {
        final res = await net.get(
            Uri.https('api.deezer.com', '/search/artist', {'q': artist, 'limit': '25'}));
        if (res.statusCode != 200) throw HttpException('Deezer HTTP ${res.statusCode}');
        return pictureCandidates(jsonDecode(res.body), artist);
      },
      ..._fallbackSources(artist),
    ];
    for (final source in sources) {
      try {
        for (final url in await source()) {
          if (!isTrustedImageUrl(url)) continue;
          try {
            final img = await net.get(Uri.parse(url));
            if (img.statusCode != 200 || img.bodyBytes.length < 200 || !looksLikeImage(img.bodyBytes)) {
              failed = true;
              continue;
            }
            await dir.create(recursive: true);
            await f.writeAsBytes(img.bodyBytes);
            if (await none.exists()) await none.delete();
            return f;
          } catch (_) {
            failed = true;
          }
        }
      } catch (_) {
        failed = true;
      }
    }
    if (!failed) {
      try {
        await dir.create(recursive: true);
        await none.writeAsString(_markerVersion);
      } catch (_) {}
    }
    return null;
  }

  /// Bumped when sources are added, so older misses are retried once.
  static const _markerVersion = 'v2';

  static final _musicianWords = RegExp(
      r'singer|musician|band|rapper|group|songwriter|duo|composer|\bDJ\b|vocalist|guitarist|producer|trio|orchestra|artist',
      caseSensitive: false);

  List<Future<List<String>> Function()> _fallbackSources(String artist) => [
        () => _audioDb(artist),
        () => _wikidataImage(artist),
        () => _wikipedia(artist),
        () => _itunes(artist),
      ];

  Future<Object?> _json(Uri uri) async {
    final res = await net.get(uri);
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) throw HttpException('${uri.host} HTTP ${res.statusCode}');
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<List<String>> _audioDb(String artist) async {
    final j = await _json(Uri.https('www.theaudiodb.com', '/api/v1/json/2/search.php', {'s': artist}));
    if (j is! Map || j['artists'] is! List) return [];
    final want = looseArtistKey(artist);
    return [
      for (final e in j['artists'] as List)
        if (e is Map &&
            looseArtistKey('${e['strArtist']}') == want &&
            e['strArtistThumb'] is String &&
            (e['strArtistThumb'] as String).isNotEmpty)
          (e['strArtistThumb'] as String).replaceFirst('http://', 'https://'),
    ];
  }

  /// MusicBrainz artist -> its Wikidata item -> the item's image on Commons.
  Future<List<String>> _wikidataImage(String artist) async {
    final search = await _json(Uri.https('musicbrainz.org', '/ws/2/artist/',
        {'query': 'artist:"${artist.replaceAll('"', '')}"', 'fmt': 'json', 'limit': '5'}));
    if (search is! Map || search['artists'] is! List) return [];
    final want = looseArtistKey(artist);
    final urls = <String>[];
    for (final a in (search['artists'] as List).whereType<Map>()) {
      if (looseArtistKey('${a['name']}') != want || a['id'] is! String) continue;
      final detail = await _json(Uri.https(
          'musicbrainz.org', '/ws/2/artist/${a['id']}', {'inc': 'url-rels', 'fmt': 'json'}));
      if (detail is! Map || detail['relations'] is! List) continue;
      for (final r in (detail['relations'] as List).whereType<Map>()) {
        final res = (r['type'] == 'wikidata' && r['url'] is Map) ? (r['url'] as Map)['resource'] : null;
        final qid = res is String ? RegExp(r'Q\d+$').firstMatch(res)?.group(0) : null;
        if (qid == null) continue;
        final ent = await _json(Uri.https('www.wikidata.org', '/wiki/Special:EntityData/$qid.json'));
        Object? claims;
        if (ent is Map && ent['entities'] is Map && (ent['entities'] as Map)[qid] is Map) {
          claims = ((ent['entities'] as Map)[qid] as Map)['claims'];
        }
        final p18 = claims is Map ? claims['P18'] : null;
        if (p18 is! List || p18.isEmpty || p18.first is! Map) continue;
        final snak = (p18.first as Map)['mainsnak'];
        final dv = snak is Map ? snak['datavalue'] : null;
        final file = dv is Map ? dv['value'] : null;
        if (file is String && file.isNotEmpty) {
          urls.add(Uri.https('commons.wikimedia.org',
              '/wiki/Special:FilePath/${file.replaceAll(' ', '_')}', {'width': '500'}).toString());
        }
      }
      if (urls.isNotEmpty) break;
    }
    return urls;
  }

  Future<List<String>> _wikipedia(String artist) async {
    for (final title in [artist, '$artist (band)', '$artist (musician)']) {
      final j = await _json(Uri.https(
          'en.wikipedia.org', '/api/rest_v1/page/summary/${title.replaceAll(' ', '_')}'));
      if (j is! Map || j['type'] != 'standard') continue;
      if (!_musicianWords.hasMatch('${j['description']}')) continue;
      final t = j['thumbnail'];
      final src = t is Map ? t['source'] : null;
      if (src is String && src.isNotEmpty) return [src];
    }
    return [];
  }

  /// Album art of the artist's releases: not a portrait, so tried last.
  Future<List<String>> _itunes(String artist) async {
    final j = await _json(Uri.https('itunes.apple.com', '/search',
        {'term': artist, 'entity': 'album', 'attribute': 'artistTerm', 'limit': '5'}));
    if (j is! Map || j['results'] is! List) return [];
    final want = looseArtistKey(artist);
    for (final m in (j['results'] as List).whereType<Map>()) {
      final u = m['artworkUrl100'];
      if (looseArtistKey('${m['artistName']}') == want && u is String) {
        return [u.replaceFirst('100x100bb', '600x600bb')];
      }
    }
    return [];
  }

  /// Picture URL of the result whose name matches [artist] (else null: a
  /// different artist's face is worse than none). Ignores Deezer's blank
  /// placeholder images.
  static String? pickPicture(Object? json, String artist) {
    final candidates = pictureCandidates(json, artist);
    return candidates.isEmpty ? null : candidates.first;
  }

  static List<String> pictureCandidates(Object? json, String artist) {
    if (json is! Map || json['data'] is! List) return [];
    final want = looseArtistKey(artist);
    final urls = <String>{};
    // Namesakes are ranked arbitrarily; the most popular one is the real artist.
    final hits = [
      for (final e in json['data'] as List)
        if (e is Map && looseArtistKey('${e['name']}') == want) e
    ];
    final order = {for (var i = 0; i < hits.length; i++) hits[i]: i};
    int fans(Map m) => m['nb_fan'] is int ? m['nb_fan'] as int : 0;
    hits.sort((a, b) => fans(b) != fans(a) ? fans(b).compareTo(fans(a)) : order[a]!.compareTo(order[b]!));
    for (final e in hits) {
      for (final k in ['picture_medium', 'picture_big', 'picture']) {
        final u = e[k];
        // Deezer serves a placeholder from an empty-path ".../artist//" url
        if (u is String && isDeezerImageUrl(u) && !u.contains('/artist//')) {
          urls.add(u);
          break;
        }
      }
    }
    return urls.toList();
  }
}
