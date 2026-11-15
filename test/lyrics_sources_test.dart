import 'dart:convert';
import 'dart:io';

import 'package:shared_core/services/enrich_service.dart';
import 'package:shared_core/services/lyrics_sources.dart';
import 'package:shared_core/services/tags.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final tags = TrackTags(title: 'Yellow', artist: 'Coldplay');
  const synced = '[00:01.00]look at the stars';
  const plain = 'Look at the stars';

  EnrichService svc(Map<String, http.Response Function(Uri)> hosts, List<String> log,
      {String? token}) {
    final s = EnrichService(
        client: MockClient((req) async {
          log.add(req.url.host);
          final h = hosts[req.url.host];
          return h == null ? http.Response('', 404) : h(req.url);
        }),
        minGap: Duration.zero);
    s.geniusToken = token;
    return s;
  }

  http.Response lrclibPlain(Uri _) =>
      http.Response(jsonEncode({'plainLyrics': plain}), 200);
  http.Response qqSynced(Uri u) => u.path.contains('client_search')
      ? http.Response(
          jsonEncode({
            'data': {
              'song': {
                'list': [
                  {'songname': 'Yellow', 'songmid': 'm1', 'singer': [{'name': 'Coldplay'}], 'interval': 266}
                ]
              }
            }
          }),
          200)
      : http.Response(jsonEncode({'lyric': base64.encode(utf8.encode(synced))}), 200);
  http.Response ovh(Uri _) => http.Response(jsonEncode({'lyrics': 'ovh text'}), 200);

  test('synced from a later source beats plain from an earlier one', () async {
    final log = <String>[];
    final hit = await svc({'lrclib.net': lrclibPlain, 'c.y.qq.com': qqSynced, 'api.lyrics.ovh': ovh}, log)
        .fetchLyricsHit(tags);
    expect(hit!.sourceId, 'qq');
    expect(hit.synced, isTrue);
    expect(log, isNot(contains('api.lyrics.ovh')));
  });

  test('falls back to LRCLIB plain before trying plain-only sources', () async {
    final log = <String>[];
    final hit = await svc({'lrclib.net': lrclibPlain, 'api.lyrics.ovh': ovh}, log).fetchLyricsHit(tags);
    expect(hit!.sourceId, 'lrclib');
    expect(hit.synced, isFalse);
    expect(log, isNot(contains('api.lyrics.ovh')));
  });

  test('plain-only sources are used when no synced lyrics exist', () async {
    final hit = await svc({'api.lyrics.ovh': ovh}, []).fetchLyricsHit(tags);
    expect(hit!.sourceId, 'ovh');
    expect(hit.text, 'ovh text');
  });

  test('one failing source does not stop the rest; all failing throws', () async {
    final s = EnrichService(
        client: MockClient((req) async {
          if (req.url.host == 'lrclib.net') throw const SocketException('x');
          return qqSynced(req.url);
        }),
        minGap: Duration.zero);
    expect((await s.fetchLyricsHit(tags))!.sourceId, 'qq');
    final dead = EnrichService(
        client: MockClient((_) async => throw const SocketException('offline')),
        minGap: Duration.zero);
    expect(dead.fetchLyricsHit(tags), throwsA(isA<SocketException>()));
  });

  test('disabled sources are skipped; Genius needs a token', () async {
    final log = <String>[];
    final s = svc({'lrclib.net': lrclibPlain, 'api.lyrics.ovh': ovh}, log);
    s.disabledSources = {for (final x in allLyricsSources) if (x.id != 'ovh') x.id};
    expect((await s.fetchLyricsHit(tags))!.sourceId, 'ovh');
    expect(log, ['api.lyrics.ovh']);
    final g = svc({}, []);
    expect(await g.fetchLyricsHit(tags), isNull);
  });

  test('Genius, Megalobiz, NetEase and ChartLyrics parse their responses', () async {
    final genius = svc({
      'api.genius.com': (_) => http.Response(
          jsonEncode({
            'response': {
              'hits': [
                {'result': {'title': 'Yellow', 'primary_artist': {'name': 'Coldplay'}, 'url': 'https://genius.com/y'}}
              ]
            }
          }),
          200),
      'genius.com': (_) => http.Response(
          '<div data-lyrics-container="true" class="x">Look at the stars<br/>It&#x27;s <a>yellow</a></div>', 200),
    }, [], token: 'tok');
    expect((await genius.fetchLyricsHit(tags))!.text, "Look at the stars\nIt's yellow");

    final mega = svc({
      'api.megalobiz.com': (u) => u.path.endsWith('/search')
          ? http.Response(
              jsonEncode({
                'results': [
                  {'title': 'Yellow', 'artist': 'Coldplay', 'duration_diff': 0.5,
                   'lrc_url': 'https://api.megalobiz.com/api/public/v1/lrc/1?format=lrc'}
                ]
              }),
              200)
          : http.Response(synced, 200),
    }, []);
    expect((await mega.fetchLyricsHit(tags, durationSec: 266))!.sourceId, 'megalobiz');

    final netease = svc({
      'music.163.com': (u) => u.path.contains('search')
          ? http.Response(
              jsonEncode({
                'result': {
                  'songs': [
                    {'id': 5, 'name': 'Yellow', 'duration': 266000, 'artists': [{'name': 'Coldplay'}]}
                  ]
                }
              }),
              200)
          : http.Response(jsonEncode({'lrc': {'lyric': synced}}), 200),
    }, []);
    expect((await netease.fetchLyricsHit(tags, durationSec: 266))!.sourceId, 'netease');

    final chart = svc({
      'api.chartlyrics.com': (_) =>
          http.Response('<GetLyricResult><Lyric>chart &amp; text</Lyric></GetLyricResult>', 200),
    }, []);
    expect((await chart.fetchLyricsHit(tags))!.text, 'chart & text');
  });

  test('mismatched artist or duration is rejected', () async {
    final s = svc({'c.y.qq.com': qqSynced}, []);
    expect(await s.fetchLyricsHit(TrackTags(title: 'Yellow', artist: 'Someone Else')), isNull);
    expect(await s.fetchLyricsHit(tags, durationSec: 100), isNull);
  });
}
