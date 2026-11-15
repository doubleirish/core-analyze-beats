import 'dart:async';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

/// Identifies these apps to public APIs that don't get a more specific one.
const defaultUserAgent = 'beats-me/1.0 (personal music player)';

/// HTTP GET with per-host pacing and 429/503 handling.
///
/// Requests to one host start at least a gap apart (slot reserved synchronously,
/// so concurrent callers queue fairly); different hosts do not wait for each
/// other. On 429/503 it honours Retry-After (else exponential backoff with
/// jitter), widens that host's gap, and after repeated failures cools the host
/// down so callers fail fast instead of hammering it.
class PoliteHttp {
  PoliteHttp({
    http.Client? client,
    Map<String, Duration>? gaps,
    this.defaultGap = const Duration(milliseconds: 500),
    this.maxRetries = 3,
    this.cooldown = const Duration(seconds: 60),
    this.maxWait = const Duration(seconds: 90),
    this.timeout = const Duration(seconds: 20),
    this.maxBodyBytes = 16 * 1024 * 1024,
    this.userAgent = defaultUserAgent,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
    math.Random? random,
  })  : _client = client ?? http.Client(),
        gaps = gaps ??
            const {
              'musicbrainz': Duration(milliseconds: 1100),
              'deezer': Duration(milliseconds: 120),
            },
        _sleep = sleep ?? Future.delayed,
        _now = now ?? DateTime.now,
        _random = random ?? math.Random();

  final http.Client _client;

  /// Base gap by host substring (e.g. 'musicbrainz').
  final Map<String, Duration> gaps;
  final Duration defaultGap;
  final int maxRetries;
  final Duration cooldown;
  final Duration maxWait;
  final Duration timeout;

  /// Largest response body accepted.
  final int maxBodyBytes;

  /// Sent with every request unless the caller sets its own.
  final String userAgent;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;
  final math.Random _random;
  final Map<String, _Host> _hosts = {};

  /// Total 429/503 responses seen, for progress reporting.
  int throttled = 0;

  Duration _baseGap(String host) {
    for (final e in gaps.entries) {
      if (host.contains(e.key)) return e.value;
    }
    return defaultGap;
  }

  /// Current pacing for [host] (grows after throttling, decays on success).
  Duration gapFor(String host) => _hosts[host]?.gap ?? _baseGap(host);

  Future<http.Response> get(Uri uri, {Map<String, String>? headers}) async {
    final host = uri.host;
    final h = _hosts.putIfAbsent(host, () => _Host(_baseGap(host)));
    for (var attempt = 0;; attempt++) {
      final now = _now();
      if (h.coolUntil != null && now.isBefore(h.coolUntil!)) {
        throw http.ClientException('$host is rate limiting; cooling down', uri);
      }
      var start = now;
      if (h.next.isAfter(start)) start = h.next;
      if (h.blockedUntil.isAfter(start)) start = h.blockedUntil;
      h.next = start.add(h.gap);
      final wait = start.difference(now);
      if (!wait.isNegative && wait > Duration.zero) await _sleep(wait);

      final res = await _fetch(uri, headers).timeout(timeout);
      if (res.statusCode != 429 && res.statusCode != 503) {
        if (++h.ok >= 20 && h.gap > _baseGap(host)) {
          h.ok = 0;
          final g = h.gap.inMilliseconds ~/ 2;
          h.gap = Duration(milliseconds: math.max(g, _baseGap(host).inMilliseconds));
        }
        return res;
      }

      throttled++;
      h.ok = 0;
      h.gap = Duration(
          milliseconds: math.min(h.gap.inMilliseconds * 2, _baseGap(host).inMilliseconds * 8));
      if (attempt >= maxRetries) {
        h.coolUntil = _now().add(cooldown);
        h.failures++;
        throw http.ClientException('$host HTTP ${res.statusCode} after $attempt retries', uri);
      }
      final backoff = retryAfter(res.headers['retry-after'], _now()) ??
          Duration(milliseconds: 2000 * (1 << attempt) + _random.nextInt(500));
      final w = backoff > maxWait ? maxWait : backoff;
      h.blockedUntil = _now().add(w);
    }
  }

  /// GET with an identifying User-Agent (unless [headers] set one) and the
  /// body capped at [maxBodyBytes], so a misbehaving server can't make us
  /// buffer an unbounded response.
  Future<http.Response> _fetch(Uri uri, Map<String, String>? headers) async {
    final req = http.Request('GET', uri)
      ..headers['user-agent'] = userAgent
      ..headers.addAll(headers ?? const {});
    final res = await _client.send(req);
    final len = res.contentLength;
    if (len != null && len > maxBodyBytes) {
      throw http.ClientException('${uri.host} response too large', uri);
    }
    final bytes = <int>[];
    await for (final chunk in res.stream) {
      bytes.addAll(chunk);
      if (bytes.length > maxBodyBytes) throw http.ClientException('${uri.host} response too large', uri);
    }
    return http.Response.bytes(bytes, res.statusCode,
        headers: res.headers, request: req, reasonPhrase: res.reasonPhrase);
  }

  /// Retry-After as delta-seconds or an HTTP date; null if absent or invalid.
  static Duration? retryAfter(String? v, DateTime now) {
    if (v == null) return null;
    final secs = int.tryParse(v.trim());
    if (secs != null) return Duration(seconds: math.max(secs, 0));
    try {
      final d = _parseHttpDate(v.trim());
      if (d == null) return null;
      final diff = d.difference(now);
      return diff.isNegative ? Duration.zero : diff;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parseHttpDate(String v) {
    final m = RegExp(r'(\d{1,2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2})').firstMatch(v);
    if (m == null) return null;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final mo = months.indexOf(m.group(2)!);
    if (mo < 0) return null;
    return DateTime.utc(int.parse(m.group(3)!), mo + 1, int.parse(m.group(1)!),
        int.parse(m.group(4)!), int.parse(m.group(5)!), int.parse(m.group(6)!));
  }
}

class _Host {
  _Host(this.gap) : next = DateTime.fromMillisecondsSinceEpoch(0);
  Duration gap;
  DateTime next;
  DateTime blockedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? coolUntil;
  int ok = 0;
  int failures = 0;
}
