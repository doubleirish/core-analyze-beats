import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'catalog.dart';
import 'importer.dart';
import 'journal.dart';
import 'manifest.dart';
import 'transports.dart';

const _tokenHeader = 'x-token';

/// Fixed default ports, so saved addresses keep working; a random port is
/// used (and advertised through discovery / QR) only when one is taken.
const pushPort = 47820;
const discoveryPort = 47821;
const pullPort = 47822;
const protocolVersion = 2;

String newPairingCode() => (Random.secure().nextInt(900000) + 100000).toString();

String newToken() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// This machine's LAN IPv4 addresses, most likely home-network first.
Future<List<String>> lanAddresses() async {
  try {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final out = [
      for (final i in ifs)
        for (final a in i.addresses)
          if (!a.isLoopback && !a.address.startsWith('169.254.')) a.address
    ];
    int rank(String a) => a.startsWith('192.168.')
        ? 0
        : a.startsWith('10.')
            ? 1
            : 2;
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  } catch (_) {
    return [];
  }
}

/// True when [host] looks like it is on the same /24 as one of [mine].
bool sameSubnet(String host, List<String> mine) {
  final h = host.split(':').first.split('.');
  if (h.length != 4) return true;
  return mine.any((m) {
    final x = m.split('.');
    return x.length == 4 && x[0] == h[0] && x[1] == h[1] && x[2] == h[2];
  });
}

Future<HttpServer> _bind(int? port, int preferred) async {
  if (port != null) return HttpServer.bind(InternetAddress.anyIPv4, port);
  try {
    return await HttpServer.bind(InternetAddress.anyIPv4, preferred);
  } on SocketException {
    return HttpServer.bind(InternetAddress.anyIPv4, 0);
  }
}

String _given(HttpRequest r) => r.headers.value(_tokenHeader) ?? '';

/// Largest JSON body the servers read (journal, pair, done, manifest).
const maxJsonBody = 4 * 1024 * 1024;

/// Requests handled at once per server; more get 503.
const maxActiveRequests = 16;

/// How long a client may take to send a JSON body.
const bodyReadTimeout = Duration(seconds: 30);

/// Largest cover image a package may carry.
const maxArtBytes = 20 * 1024 * 1024;

/// Reads a UTF-8 request body of at most [limit] bytes; throws
/// [_TooLarge] when the client declares or sends more.
Future<String> readBody(HttpRequest r, {int limit = maxJsonBody}) async {
  if (r.contentLength > limit) throw _TooLarge();
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in r.timeout(bodyReadTimeout)) {
    if (bytes.length + chunk.length > limit) throw _TooLarge();
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes());
}

class _TooLarge implements Exception {}

/// Only peers on a private network (or this machine) may talk to the servers.
bool isLanPeer(InternetAddress? a) {
  if (a == null) return false;
  if (a.isLoopback || a.isLinkLocal) return true;
  final b = a.rawAddress;
  if (a.type != InternetAddressType.IPv4 || b.length != 4) return false;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 100 && b[1] >= 64 && b[1] < 128); // CGNAT, used by some hotspots
}

/// Common request gate: LAN peers only, bounded concurrency, and size/
/// timeout failures answered with a proper status instead of a 500.
Future<void> _guarded(HttpRequest r, int Function(int) active, Future<void> Function() route,
    {void Function(String)? onError}) async {
  if (!isLanPeer(r.connectionInfo?.remoteAddress)) {
    r.response.statusCode = HttpStatus.forbidden;
    return r.response.close();
  }
  if (active(1) > maxActiveRequests) {
    active(-1);
    return _reply(r, 503, {'error': 'busy'});
  }
  try {
    await route();
  } on _TooLarge {
    await _safeReply(r, 413, {'error': 'request too large'});
  } on TimeoutException {
    await _safeReply(r, 408, {'error': 'request timed out'});
  } on FormatException catch (e) {
    await _safeReply(r, 400, {'error': e.message});
  } catch (e) {
    onError?.call('$e');
    await _safeReply(r, 500, {'error': 'internal error'});
  } finally {
    active(-1);
  }
}

Future<void> _safeReply(HttpRequest r, int status, Object body) async {
  try {
    await _reply(r, status, body);
  } catch (_) {}
}

bool _same(String given, String token) {
  if (token.isEmpty || given.length != token.length) return false;
  var diff = 0;
  for (var i = 0; i < token.length; i++) {
    diff |= given.codeUnitAt(i) ^ token.codeUnitAt(i);
  }
  return diff == 0;
}

Future<void> _reply(HttpRequest r, int status, Object body) async {
  r.response.statusCode = status;
  r.response.headers.contentType = ContentType.json;
  r.response.write(jsonEncode(body));
  await r.response.close();
}

/// The phone's import report (`{copied, reused, errors}`) with only the
/// known fields kept: counts as non-negative ints, at most 50 short errors.
Map<String, dynamic> doneReport(Map body) {
  int count(Object? v) => v is num && v >= 0 ? min(v.toInt(), 1 << 30) : 0;
  final errors = body['errors'];
  return {
    'copied': count(body['copied']),
    'reused': count(body['reused']),
    'errors': [
      if (errors is List)
        for (final e in errors.take(50))
          if (e is String) e.length > 300 ? '${e.substring(0, 300)}…' : e
    ],
  };
}

/// Journal entries on the wire: `{"entries": [JournalEntry.toJson…]}`.
String encodeJournalBody(List<JournalEntry> entries) =>
    jsonEncode({'entries': [for (final e in entries) e.toJson()]});

/// Reads [encodeJournalBody] output, or plain JSONL; bad entries are skipped.
List<JournalEntry> decodeJournalBody(String text) {
  try {
    final j = jsonDecode(text);
    if (j is Map && j['entries'] is List) return _entriesOf(j['entries'] as List);
  } catch (_) {}
  return parseJournal(text);
}

List<JournalEntry> _entriesOf(List list) {
  final out = <JournalEntry>[];
  for (final e in list) {
    try {
      out.add(JournalEntry.fromJson((e as Map).cast<String, dynamic>()));
    } catch (_) {}
  }
  return out;
}

enum TransferError { unreachable, refused, auth, declined, server, corrupt, cancelled }

/// A transfer failure with a message written for the user.
class TransferException implements Exception {
  TransferException(this.message, [this.kind = TransferError.server]);
  final String message;
  final TransferError kind;
  @override
  String toString() => message;
}

/// Turns a socket failure into advice. [peerIsPc] when the phone is the client.
TransferException _socketError(SocketException e, {required bool peerIsPc}) {
  final code = e.osError?.errorCode;
  final refused = code == 111 || code == 10061 || e.message.toLowerCase().contains('refused');
  if (refused) {
    return TransferException(
        peerIsPc
            ? 'The PC is not sharing right now. In analyze-this press Send › "Wi-Fi (phone downloads)" again.'
            : 'The phone was found but isn\'t receiving. Unlock it and open beats-me (with "Receive mixes '
                'from PC while beats-me is open" on), or open beats-me › Get mixes from PC.',
        TransferError.refused);
  }
  return TransferException(
      peerIsPc
          ? 'Can\'t reach the PC. Check both are on the same Wi-Fi (not a guest network). '
              'If they are, Windows Firewall is blocking analyze-this: Windows Security › Firewall › '
              '"Allow an app" › tick analyze-this for Private networks.'
          : 'Can\'t reach the phone. Check both are on the same Wi-Fi (not a guest network) '
              'and the phone is unlocked with beats-me open.',
      TransferError.unreachable);
}

class RemoteMixtape {
  RemoteMixtape(this.id, this.name, this.tracks, this.createdAt, [this.bytes = 0]);
  final String id, name;
  final int tracks, createdAt, bytes;
}

// ----------------------------------------------------------- QR link ----

/// What the PC's QR code holds: `beatsme://pull?h=ip1,ip2&p=port&t=token&n=name`.
class PullLink {
  PullLink({required this.hosts, required this.port, required this.token, this.name});
  final List<String> hosts;
  final int port;
  final String token;
  final String? name;

  @override
  String toString() => Uri(scheme: 'beatsme', host: 'pull', queryParameters: {
        'h': hosts.join(','),
        'p': '$port',
        't': token,
        'n': ?name,
      }).toString();

  static PullLink? parse(String text) {
    final u = Uri.tryParse(text.trim());
    if (u == null || u.scheme != 'beatsme' || u.host != 'pull') return null;
    final q = u.queryParameters;
    final hosts = (q['h'] ?? '').split(',').where((h) => h.isNotEmpty).toList();
    final port = int.tryParse(q['p'] ?? '');
    final token = q['t'] ?? '';
    if (hosts.isEmpty || port == null || token.isEmpty) return null;
    return PullLink(hosts: hosts, port: port, token: token, name: q['n']);
  }
}

// ---------------------------------------------------------------- pull ----

/// PC side of the pull transport: serves packages exported with the `pull`
/// label from `<root>/pull/` to a paired phone on the LAN.
class PullServer {
  PullServer({required this.root, String? token, this.name, this.onPhoneDone, this.onJournal})
      : token = token ?? newPairingCode();
  final Directory root;
  final String token;
  final String? name;

  /// Called when the phone reports it finished importing a mixtape.
  final void Function(String id, Map<String, dynamic> report)? onPhoneDone;

  /// Imports the phone's play/rating journal (`POST /pull/v1/journal`, body
  /// `{"entries": [JournalEntry.toJson…]}` or JSONL) and returns the highest
  /// seq the phone may trim up to (replied as `{"ackSeq": n}`). When null the
  /// route answers 404, like an older PC.
  final Future<int> Function(List<JournalEntry> entries)? onJournal;
  HttpServer? _server;

  int? get port => _server?.port;
  bool get running => _server != null;

  Future<void> start({int? port}) async {
    _server = await _bind(port, pullPort);
    _server!.listen((r) => unawaited(_handle(r).catchError((_) {})));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<PullLink> link() async =>
      PullLink(hosts: await lanAddresses(), port: port ?? pullPort, token: token, name: name);

  int _active = 0;

  Future<void> _handle(HttpRequest r) => _guarded(r, (d) => _active += d, () => _route(r));

  Future<void> _route(HttpRequest r) async {
    if (!_same(_given(r), token)) return _reply(r, 401, {'error': 'bad pairing code'});
    final seg = r.uri.pathSegments;
    if (seg.length < 3 || seg[0] != Transport.pull || seg[1] != 'v1') {
      return _reply(r, 404, {'error': 'not found'});
    }
    if (r.method == 'GET' && seg[2] == 'mixtapes') {
      return _reply(r, 200, [
        for (final f in await discoverPackages(root, Transport.pull))
          {
            'id': f.manifest.id,
            'name': f.manifest.name,
            'tracks': f.manifest.tracks.length,
            'createdAt': f.manifest.createdAt,
            'bytes': f.manifest.totalBytes,
          }
      ]);
    }
    if (r.method == 'POST' && seg.length == 3 && seg[2] == 'journal') {
      final cb = onJournal;
      if (cb == null) return _reply(r, 404, {'error': 'not found'});
      final entries = decodeJournalBody(await readBody(r));
      return _reply(r, 200, {'ackSeq': await cb(entries)});
    }
    final id = seg[2];
    if (!isSafeId(id)) return _reply(r, 404, {'error': 'unknown mixtape'});
    final dir = labelDir(root, Transport.pull, id);
    if (!await File(p.join(dir.path, manifestName)).exists()) {
      return _reply(r, 404, {'error': 'unknown mixtape'});
    }
    if (r.method == 'POST' && seg.length == 4 && seg[3] == 'done') {
      final body = jsonDecode(await readBody(r, limit: 64 * 1024));
      if (body is! Map) return _reply(r, 400, {'error': 'bad report'});
      onPhoneDone?.call(id, doneReport(body));
      return _reply(r, 200, {'ok': true});
    }
    if (r.method != 'GET') return _reply(r, 404, {'error': 'not found'});
    if (seg.length == 4 && seg[3] == manifestName) {
      r.response.headers.contentType = ContentType.json;
      await r.response.addStream(File(p.join(dir.path, manifestName)).openRead());
      return r.response.close();
    }
    if (seg.length >= 5 && seg[3] == 'file') {
      final rel = seg.sublist(4).join('/');
      final m = MixtapeManifest.decode(await File(p.join(dir.path, manifestName)).readAsString());
      if (!safeRelative(rel) || !m.files.contains(rel)) {
        return _reply(r, 404, {'error': 'unknown file'});
      }
      return _sendFile(r, File(p.join(dir.path, rel)));
    }
    return _reply(r, 404, {'error': 'not found'});
  }

  Future<void> _sendFile(HttpRequest r, File f) async {
    final len = await f.length();
    var start = 0;
    final range = RegExp(r'bytes=(\d+)-').firstMatch(r.headers.value('range') ?? '');
    if (range != null) start = min(int.parse(range.group(1)!), len);
    r.response.headers.contentType = ContentType.binary;
    r.response.headers.set('accept-ranges', 'bytes');
    if (start > 0) {
      r.response.statusCode = HttpStatus.partialContent;
      r.response.headers.set('content-range', 'bytes $start-${len - 1}/$len');
    }
    r.response.contentLength = len - start;
    await r.response.addStream(f.openRead(start));
    await r.response.close();
  }
}

/// Phone side of the pull transport.
class PullClient {
  PullClient(this.base, this.token);
  final Uri base;
  final String token;

  /// Tries every address in [link] and returns a client for the first that
  /// answers.
  static Future<PullClient> reach(PullLink link) async {
    TransferException? last;
    for (final h in link.hosts) {
      final c = PullClient(Uri.parse('http://$h:${link.port}'), link.token);
      try {
        await c.list(timeout: const Duration(seconds: 4));
        return c;
      } on TransferException catch (e) {
        if (e.kind == TransferError.auth) rethrow;
        last = e;
      }
    }
    throw last ?? TransferException('The QR code has no address.');
  }

  Future<T> _send<T>(String method, String path, Future<T> Function(HttpClientResponse) use,
      {int from = 0,
      List<int>? body,
      Duration timeout = const Duration(seconds: 8),
      Set<int> passStatus = const {}}) async {
    final c = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await c.openUrl(method, base.replace(path: path));
      req.headers.set(_tokenHeader, token);
      if (from > 0) req.headers.set('range', 'bytes=$from-');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close();
      if (passStatus.contains(res.statusCode)) return await use(res);
      if (res.statusCode == 401) {
        throw TransferException(
            'The PC rejected the code. Scan the QR code again (it changes when sharing restarts).',
            TransferError.auth);
      }
      if (res.statusCode >= 400) {
        throw TransferException('The PC replied with an error (${res.statusCode}).');
      }
      return await use(res);
    } on SocketException catch (e) {
      throw _socketError(e, peerIsPc: true);
    } on HttpException catch (e) {
      throw TransferException('Connection to the PC dropped (${e.message}).', TransferError.unreachable);
    } finally {
      c.close(force: true);
    }
  }

  Future<List<RemoteMixtape>> list({Duration timeout = const Duration(seconds: 8)}) =>
      _send('GET', '/${Transport.pull}/v1/mixtapes', (res) async {
        final j = jsonDecode(await utf8.decodeStream(res)) as List;
        return [
          for (final m in j.cast<Map>())
            RemoteMixtape(m['id'] as String, m['name'] as String, (m['tracks'] as num).toInt(),
                (m['createdAt'] as num).toInt(), (m['bytes'] as num?)?.toInt() ?? 0)
        ];
      }, timeout: timeout);

  /// Tells the PC how the import went, so it can show the result.
  Future<void> reportDone(String id, Map<String, dynamic> report) async {
    try {
      await _send('POST', '/${Transport.pull}/v1/$id/done', (res) => res.drain<void>(),
          body: utf8.encode(jsonEncode(report)));
    } catch (_) {}
  }

  /// Sends the phone's journal entries to the PC and returns the seq the
  /// phone may trim up to, or null when the PC doesn't take journals (404).
  /// Throws [TransferException] on other failures.
  Future<int?> sendJournal(List<JournalEntry> entries) =>
      _send('POST', '/${Transport.pull}/v1/journal', (res) async {
        final text = await utf8.decodeStream(res);
        if (res.statusCode == 404) return null;
        final j = jsonDecode(text);
        return j is Map ? (j['ackSeq'] as num?)?.toInt() : null;
      }, body: utf8.encode(encodeJournalBody(entries)), passStatus: const {404});

  /// Downloads the package into `staging/<id>`. Songs for which [haveSong]
  /// is true are skipped; partial downloads resume, and a dropped connection
  /// is retried a few times before giving up.
  Future<Directory> download(
    String id,
    Directory staging, {
    Future<bool> Function(MixtapeManifest, MixtapeTrack)? haveSong,
    void Function(int done, int total, String what)? onProgress,
    bool Function()? cancelled,
  }) async {
    final root = '/${Transport.pull}/v1/$id';
    final m = await _send('GET', '$root/$manifestName',
        (res) async => MixtapeManifest.decode(await utf8.decodeStream(res)));
    if (m.transport != Transport.pull) {
      throw TransferException('Package label is "${m.transport}", expected "pull"');
    }
    final dir = Directory(p.join(staging.path, sanitizeName(id)));
    await dir.create(recursive: true);

    final want = <String, ({int size, String sha})>{};
    for (final t in m.tracks) {
      if (!safeRelative(t.file)) throw TransferException('Unsafe path ${t.file}');
      if (haveSong == null || !await haveSong(m, t)) {
        want[t.file] = (size: t.size, sha: t.sha256);
        if (t.art != null && safeRelative(t.art!)) {
          want.putIfAbsent(t.art!, () => (size: -1, sha: ''));
        }
      }
    }
    final total = want.values.fold<int>(0, (a, v) => a + max(v.size, 0));
    var doneBytes = 0;
    for (final e in want.entries) {
      if (cancelled?.call() ?? false) throw TransferException('Cancelled', TransferError.cancelled);
      onProgress?.call(doneBytes, total, p.basename(e.key));
      final f = File(p.join(dir.path, e.key));
      if (e.value.size >= 0 && await fileMatches(f, e.value.size, e.value.sha)) {
        doneBytes += e.value.size;
        continue;
      }
      await f.parent.create(recursive: true);
      final part = File('${f.path}.part');
      final url = '$root/file/${e.key.split('/').map(Uri.encodeComponent).join('/')}';
      for (var attempt = 1;; attempt++) {
        final have = await part.exists() ? await part.length() : 0;
        try {
          await _send('GET', url, (res) async {
            final append = res.statusCode == HttpStatus.partialContent;
            final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
            var got = append ? have : 0;
            var last = 0;
            try {
              await sink.addStream(res.map((chunk) {
                got += chunk.length;
                if (got > (e.value.size >= 0 ? e.value.size : maxArtBytes)) {
                  throw TransferException(
                      'A song arrived damaged (${e.key}). Try again.', TransferError.corrupt);
                }
                if (got - last > 256 * 1024) {
                  last = got;
                  onProgress?.call(doneBytes + got, total, p.basename(e.key));
                }
                return chunk;
              }));
            } finally {
              await sink.close();
            }
          }, from: have);
          break;
        } on TransferException catch (err) {
          if (err.kind != TransferError.unreachable || attempt >= 4) rethrow;
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
      if (await f.exists()) await f.delete();
      await part.rename(f.path);
      if (e.value.size >= 0 && !await fileMatches(f, e.value.size, e.value.sha)) {
        await f.delete();
        throw TransferException('A song arrived damaged (${e.key}). Try again.', TransferError.corrupt);
      }
      doneBytes += max(e.value.size, 0);
    }
    await File(p.join(dir.path, manifestName)).writeAsString(m.encode());
    onProgress?.call(total, total, 'done');
    return dir;
  }
}

// ---------------------------------------------------------------- push ----

/// A PC asking to be trusted by the phone.
class PairRequest {
  PairRequest(this.name, this.id, this.code, this.address);
  final String name, id, code, address;
}

class PhoneHello {
  PhoneHello(this.name, this.id, this.version, this.freeBytes, {this.catalog = false});
  final String name, id;
  final int version;
  final int? freeBytes;
  final bool catalog;
}

class PairResult {
  PairResult(this.token, this.name, this.id);
  final String token, name, id;
}

/// Phone side of the push transport: receives a package from the PC, then
/// installs it with [importer]. Accepts the session [token] (manual entry,
/// while [acceptToken]) or any token [isTrusted] knows (paired PCs).
class PushReceiver {
  PushReceiver({
    required this.importer,
    required this.staging,
    String? token,
    this.deviceName = 'phone',
    this.deviceId = '',
    this.isTrusted,
    this.onPair,
    this.freeBytes,
    this.onProgress,
    this.onFileProgress,
    this.onImported,
    this.onError,
    this.acceptToken = true,
    this.journal,
    this.ackJournal,
    this.onCatalog,
  }) : token = token ?? newPairingCode();

  final MixtapeImporter importer;
  final Directory staging;
  final String token;
  final String deviceName, deviceId;
  final bool Function(String token)? isTrusted;

  /// Whether the session [token] is accepted. Turn off while nobody can see
  /// it (e.g. receiving in the background) so only paired PCs get in.
  bool acceptToken;

  /// Asks the user; returns a long-lived token to hand the PC, or null.
  final Future<String?> Function(PairRequest)? onPair;
  final Future<int?> Function()? freeBytes;
  final void Function(String message)? onProgress;
  final void Function(int done, int total, String what)? onFileProgress;
  final void Function(ImportResult)? onImported;
  final void Function(String)? onError;

  /// Journal entries with seq > `since`, for `GET /push/v1/journal?since=N`
  /// (reply `{"entries": [...]}`). Paired PCs only; 404 when null.
  final Future<List<JournalEntry>> Function(int since)? journal;

  /// Called for `POST /push/v1/ack?upTo=N` once the PC stored the entries up
  /// to N, so the phone can trim them. Paired PCs only; 404 when null.
  final Future<void> Function(int upTo)? ackJournal;
  final Future<void> Function(AlbumCatalog)? onCatalog;
  HttpServer? _server;
  final Map<String, ({int total, int done})> _bytes = {};

  int? get port => _server?.port;
  bool get running => _server != null;

  Future<void> start({int? port}) async {
    _server = await _bind(port, pushPort);
    _server!.listen((r) => unawaited(_handle(r).catchError((_) {})));
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Directory _dir(String id) => Directory(p.join(staging.path, sanitizeName(id)));

  int _active = 0;

  Future<void> _handle(HttpRequest r) =>
      _guarded(r, (d) => _active += d, () => _route(r), onError: onError);

  bool _authorised(HttpRequest r) {
    final g = _given(r);
    return (acceptToken && _same(g, token)) || (g.isNotEmpty && (isTrusted?.call(g) ?? false));
  }

  Future<void> _route(HttpRequest r) async {
    final seg = r.uri.pathSegments;
    if (seg.length != 3 || seg[0] != Transport.push || seg[1] != 'v1') {
      return _reply(r, 404, {'error': 'not found'});
    }
    if (r.method == 'POST' && seg[2] == 'pair') return _pair(r);
    if (!_authorised(r)) return _reply(r, 401, {'error': 'not paired'});
    switch ('${r.method} ${seg[2]}') {
      case 'GET hello':
        return _reply(r, 200, {
          'name': deviceName,
          'id': deviceId,
          'version': protocolVersion,
          'free': await freeBytes?.call(),
          'catalog': onCatalog != null,
        });
      case 'POST begin':
        return _begin(r);
      case 'GET status':
        return _status(r);
      case 'PUT file':
        return _file(r);
      case 'POST commit':
        return _commit(r);
      case 'PUT catalog':
        final cb = onCatalog;
        if (cb == null) return _reply(r, 404, {'error': 'not found'});
        if (!_paired(r)) return _reply(r, 401, {'error': 'not paired'});
        final catalog = AlbumCatalog.decode(await readBody(r, limit: maxAlbumCatalogBytes));
        await cb(catalog);
        return _reply(r, 200, {'ok': true, 'albums': catalog.albums.length});
      case 'GET journal':
        final cb = journal;
        if (cb == null) return _reply(r, 404, {'error': 'not found'});
        if (!_paired(r)) return _reply(r, 401, {'error': 'not paired'});
        final since = int.tryParse(r.uri.queryParameters['since'] ?? '') ?? 0;
        r.response.headers.contentType = ContentType.json;
        r.response.write(encodeJournalBody(await cb(since)));
        return r.response.close();
      case 'POST ack':
        final cb = ackJournal;
        if (cb == null) return _reply(r, 404, {'error': 'not found'});
        if (!_paired(r)) return _reply(r, 401, {'error': 'not paired'});
        final upTo = int.tryParse(r.uri.queryParameters['upTo'] ?? '');
        if (upTo == null) return _reply(r, 400, {'error': 'upTo missing'});
        await cb(upTo);
        return _reply(r, 200, {'ok': true});
    }
    return _reply(r, 404, {'error': 'not found'});
  }

  /// Only paired PCs (trusted tokens) may read or trim the journal; the
  /// one-time session code is not enough.
  bool _paired(HttpRequest r) {
    final g = _given(r);
    return g.isNotEmpty && (isTrusted?.call(g) ?? false);
  }

  Future<void> _pair(HttpRequest r) async {
    final j = jsonDecode(await readBody(r, limit: 16 * 1024));
    if (j is! Map) return _reply(r, 400, {'error': 'bad request'});
    final ask = onPair;
    if (ask == null) return _reply(r, 403, {'error': 'Pairing is off on this phone'});
    String field(Object? v, String fallback) {
      final s = v == null ? fallback : '$v';
      return s.length > 100 ? s.substring(0, 100) : s;
    }

    final req = PairRequest(field(j['name'], 'PC'), field(j['id'], ''), field(j['code'], ''),
        r.connectionInfo?.remoteAddress.address ?? '');
    String? tok;
    try {
      tok = await ask(req).timeout(const Duration(seconds: 90));
    } on TimeoutException {
      tok = null;
    }
    if (tok == null) {
      return _reply(r, 403, {
        'error': 'The phone didn\'t allow this PC. To pair, open beats-me › Get mixes from PC on the '
            'phone, send again and tap Allow.'
      });
    }
    return _reply(r, 200, {'token': tok, 'name': deviceName, 'id': deviceId});
  }

  Future<File?> _target(String id, String rel) async {
    if (!isSafeId(id)) return null;
    final mf = File(p.join(_dir(id).path, manifestName));
    if (!safeRelative(rel) || !await mf.exists()) return null;
    final m = MixtapeManifest.decode(await mf.readAsString());
    if (!m.files.contains(rel)) return null;
    return File(p.join(_dir(id).path, rel));
  }

  Future<void> _begin(HttpRequest r) async {
    final m = MixtapeManifest.decode(await readBody(r, limit: maxManifestChars));
    if (m.transport != Transport.push) {
      return _reply(r, 409,
          {'error': 'Package label is "${m.transport}", this receiver only takes "push"'});
    }
    final dir = _dir(m.id);
    await dir.create(recursive: true);
    final missing = <String>[];
    final partial = <String, int>{};
    var total = 0;
    Future<void> want(String rel, int size) async {
      missing.add(rel);
      total += max(size, 0);
      final part = File('${p.join(dir.path, rel)}.part');
      if (await part.exists()) partial[rel] = await part.length();
    }

    for (final t in m.tracks) {
      if (!safeRelative(t.file)) return _reply(r, 400, {'error': 'unsafe path ${t.file}'});
      final installed = await importer.hasTrack(m, t);
      // A copy in another mixtape is reused; only its art may be needed.
      final songHere = installed || await importer.hasSong(m, t);
      if (!songHere && !await fileMatches(File(p.join(dir.path, t.file)), t.size, t.sha256)) {
        await want(t.file, t.size);
      }
      if (!installed &&
          t.art != null &&
          safeRelative(t.art!) &&
          !missing.contains(t.art!) &&
          !await File(p.join(dir.path, t.art!)).exists()) {
        await want(t.art!, -1);
      }
    }
    await File(p.join(dir.path, manifestName)).writeAsString(m.encode());
    _bytes[m.id] = (total: total, done: 0);
    onProgress?.call('Receiving "${m.name}" (${missing.length} files, ${formatBytes(total)})');
    onFileProgress?.call(0, total, m.name);
    return _reply(r, 200, {'missing': missing, 'partial': partial});
  }

  Future<void> _status(HttpRequest r) async {
    final f = await _target(r.uri.queryParameters['id'] ?? '', r.uri.queryParameters['path'] ?? '');
    if (f == null) return _reply(r, 400, {'error': 'bad request'});
    final part = File('${f.path}.part');
    return _reply(r, 200, {'partial': await part.exists() ? await part.length() : 0});
  }

  Future<void> _file(HttpRequest r) async {
    final id = r.uri.queryParameters['id'] ?? '';
    final rel = r.uri.queryParameters['path'] ?? '';
    final offset = int.tryParse(r.uri.queryParameters['offset'] ?? '0') ?? 0;
    final f = await _target(id, rel);
    if (f == null) return _reply(r, 400, {'error': 'file not in manifest'});
    await f.parent.create(recursive: true);
    final part = File('${f.path}.part');
    final have = await part.exists() ? await part.length() : 0;
    if (offset > 0 && offset != have) {
      await r.drain<void>();
      return _reply(r, 409, {'partial': have});
    }
    final m = MixtapeManifest.decode(await File(p.join(_dir(id).path, manifestName)).readAsString());
    final t = m.tracks.where((t) => t.file == rel).firstOrNull;
    // Songs may not exceed their manifest size; art has no size, so cap it.
    final limit = t?.size ?? maxArtBytes;
    final sink = part.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
    final b = _bytes[id];
    var got = 0;
    var tooBig = false;
    try {
      await sink.addStream(r.timeout(const Duration(seconds: 60)).takeWhile((c) {
        tooBig = offset + got + c.length > limit;
        return !tooBig;
      }).map((c) {
        got += c.length;
        if (b != null && got % (512 * 1024) < c.length) {
          onFileProgress?.call(b.done + offset + got, b.total, p.basename(rel));
        }
        return c;
      }));
    } finally {
      await sink.close();
    }
    if (tooBig) {
      await part.delete();
      throw _TooLarge();
    }
    if (t != null && !await fileMatches(part, t.size, t.sha256)) {
      await part.delete();
      return _reply(r, 422, {'error': 'damaged in transfer'});
    }
    if (await f.exists()) await f.delete();
    await part.rename(f.path);
    final size = await f.length();
    if (b != null) _bytes[id] = (total: b.total, done: b.done + size);
    onFileProgress?.call(_bytes[id]?.done ?? 0, b?.total ?? 0, p.basename(rel));
    return _reply(r, 200, {'ok': true});
  }

  Future<void> _commit(HttpRequest r) async {
    final id = r.uri.queryParameters['id'] ?? '';
    if (!isSafeId(id)) return _reply(r, 400, {'error': 'nothing staged'});
    final dir = _dir(id);
    if (!await File(p.join(dir.path, manifestName)).exists()) {
      return _reply(r, 400, {'error': 'nothing staged'});
    }
    onProgress?.call('Installing…');
    ImportResult res;
    try {
      res = await importer.importPackage(dir, move: true);
    } on ImportException catch (e) {
      onError?.call(e.message);
      return _reply(r, 422, {'error': e.message});
    }
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    _bytes.remove(id);
    onImported?.call(res);
    return _reply(r, 200, {
      'copied': res.copied,
      'reused': res.reused,
      'errors': res.errors,
    });
  }
}

class PushResult {
  PushResult(this.sent, this.skipped, this.copied, this.errors, [this.bytes = 0]);
  final int sent, skipped, copied, bytes;
  final List<String> errors;
}

/// PC side of the push transport.
class PushSender {
  PushSender(this.base, this.token);
  final Uri base;
  final String token;

  static Future<Map<String, dynamic>> _call(
    Uri base,
    String? token,
    String method,
    String path,
    Stream<List<int>> body, {
    int? length,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 8),
    Set<int> passStatus = const {},
  }) async {
    final c = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await c.openUrl(
          method, base.replace(path: '/${Transport.push}/v1/$path', queryParameters: query));
      if (token != null) req.headers.set(_tokenHeader, token);
      if (length != null) req.contentLength = length;
      await req.addStream(body);
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      Map<String, dynamic> j;
      try {
        j = text.isEmpty ? <String, dynamic>{} : (jsonDecode(text) as Map).cast<String, dynamic>();
      } catch (_) {
        j = {'error': text};
      }
      if (passStatus.contains(res.statusCode)) return {...j, '_status': res.statusCode};
      if (res.statusCode == 401) {
        throw TransferException(
            'The phone doesn\'t recognise this PC any more. Pair again.', TransferError.auth);
      }
      if (res.statusCode == 403) {
        throw TransferException((j['error'] as String?) ?? 'Declined on the phone.', TransferError.declined);
      }
      if (res.statusCode >= 400) {
        throw TransferException((j['error'] as String?) ?? 'Phone replied ${res.statusCode}');
      }
      return j;
    } on SocketException catch (e) {
      throw _socketError(e, peerIsPc: false);
    } on HttpException catch (e) {
      throw TransferException('Connection to the phone dropped (${e.message}).', TransferError.unreachable);
    } finally {
      c.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _me(String method, String path, Stream<List<int>> body,
          {int? length, Map<String, String>? query, Set<int> passStatus = const {}}) =>
      _call(base, token, method, path, body,
          length: length, query: query, passStatus: passStatus);

  /// Asks the phone to trust this PC. The phone shows [code]; the user
  /// accepts there. Waits up to ~90 s for the answer.
  static Future<PairResult> pair(Uri base,
      {required String pcName, required String pcId, required String code}) async {
    final body = utf8.encode(jsonEncode({'name': pcName, 'id': pcId, 'code': code}));
    final j = await _call(base, null, 'POST', 'pair', Stream.value(body), length: body.length);
    return PairResult(j['token'] as String, '${j['name'] ?? 'phone'}', '${j['id'] ?? ''}');
  }

  Future<PhoneHello> hello() async {
    final j = await _me('GET', 'hello', const Stream.empty());
    return PhoneHello('${j['name'] ?? 'phone'}', '${j['id'] ?? ''}',
        (j['version'] as num?)?.toInt() ?? 1, (j['free'] as num?)?.toInt(),
        catalog: j['catalog'] == true);
  }

  Future<void> sendCatalog(AlbumCatalog catalog) async {
    final body = utf8.encode(catalog.encode());
    final j = await _call(base, token, 'PUT', 'catalog', Stream.value(body),
        length: body.length, timeout: const Duration(seconds: 30), passStatus: {404});
    if (j['_status'] == 404) {
      throw TransferException('Update beats-me on the phone to receive the album list.');
    }
    if (j['ok'] != true) throw TransferException('The phone did not confirm the album list.');
  }

  /// The phone's journal entries with seq > [since]. Phones without journal
  /// sync (older beats-me) answer 404, giving an empty list.
  Future<List<JournalEntry>> journal({int since = 0}) async {
    final j = await _me('GET', 'journal', const Stream.empty(),
        query: {'since': '$since'}, passStatus: {404});
    if (j['_status'] == 404) return [];
    return _entriesOf((j['entries'] as List?) ?? const []);
  }

  /// Lets the phone trim its journal up to [upTo]; a no-op on older phones.
  Future<void> ackJournal(int upTo) async {
    await _me('POST', 'ack', const Stream.empty(),
        length: 0, query: {'upTo': '$upTo'}, passStatus: {404});
  }

  /// Sends the package in [pkg] (written with the `push` label), uploading
  /// only the files the phone doesn't have yet. Interrupted uploads resume
  /// where they stopped; each file is retried a few times.
  Future<PushResult> send(
    Directory pkg, {
    void Function(int done, int total, String what)? onProgress,
    bool Function()? cancelled,
  }) async {
    final m = await MixtapeImporter.readManifest(pkg);
    if (m.transport != Transport.push) {
      throw TransferException('Package label is "${m.transport}", expected "push"');
    }
    final bytes = utf8.encode(m.encode());
    final begin = await _me('POST', 'begin', Stream.value(bytes), length: bytes.length);
    final missing = (begin['missing'] as List).cast<String>();
    final partial = ((begin['partial'] as Map?) ?? const {}).cast<String, dynamic>();
    var total = 0;
    for (final rel in missing) {
      total += await File(p.join(pkg.path, rel)).length();
    }
    var done = 0;
    for (final rel in missing) {
      final f = File(p.join(pkg.path, rel));
      final size = await f.length();
      var offset = (partial[rel] as num?)?.toInt() ?? 0;
      if (offset > size) offset = 0;
      for (var attempt = 1;; attempt++) {
        if (cancelled?.call() ?? false) throw TransferException('Cancelled', TransferError.cancelled);
        onProgress?.call(done + offset, total, p.basename(rel));
        try {
          var sent = offset;
          var last = 0;
          final j = await _me(
            'PUT',
            'file',
            f.openRead(offset).map((c) {
              sent += c.length;
              if (sent - last > 256 * 1024) {
                last = sent;
                onProgress?.call(done + sent, total, p.basename(rel));
              }
              return c;
            }),
            length: size - offset,
            query: {'id': m.id, 'path': rel, 'offset': '$offset'},
            passStatus: {409, 422},
          );
          if (j['_status'] == 409) {
            offset = (j['partial'] as num?)?.toInt() ?? 0;
            if (attempt >= 4) throw TransferException('Upload kept going out of step; try again.');
            continue;
          }
          if (j['_status'] == 422) {
            offset = 0;
            if (attempt >= 3) {
              throw TransferException('$rel keeps arriving damaged. Check the Wi-Fi signal.',
                  TransferError.corrupt);
            }
            continue;
          }
          break;
        } on TransferException catch (e) {
          if (e.kind != TransferError.unreachable || attempt >= 4) rethrow;
          await Future<void>.delayed(Duration(seconds: attempt));
          try {
            final s = await _me('GET', 'status', const Stream.empty(),
                query: {'id': m.id, 'path': rel});
            offset = (s['partial'] as num?)?.toInt() ?? 0;
          } on TransferException {
            offset = 0;
          }
        }
      }
      done += size;
    }
    final res = await _me('POST', 'commit', const Stream.empty(), length: 0, query: {'id': m.id});
    onProgress?.call(total, total, 'done');
    return PushResult(missing.length, m.files.length - missing.length,
        (res['copied'] as num?)?.toInt() ?? 0, [for (final e in (res['errors'] as List?) ?? const []) '$e'],
        total);
  }
}
