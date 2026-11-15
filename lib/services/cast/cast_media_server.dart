import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Content type a Cast device needs for the audio file [path].
String castContentType(String path) {
  switch (p.extension(path).toLowerCase()) {
    case '.m4a':
    case '.mp4':
    case '.aac':
      return 'audio/mp4';
    case '.flac':
      return 'audio/flac';
    case '.wav':
      return 'audio/wav';
    case '.ogg':
    case '.oga':
    case '.opus':
      return 'audio/ogg';
    default:
      return 'audio/mpeg';
  }
}

/// Parses an HTTP `Range: bytes=a-b` header for a file of [length] bytes.
/// Returns (start, endInclusive), or null when absent/unsatisfiable.
(int, int)? parseByteRange(String? header, int length) {
  if (header == null || length <= 0) return null;
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (m == null) return null;
  final a = m.group(1)!, b = m.group(2)!;
  if (a.isEmpty && b.isEmpty) return null;
  int start, end;
  if (a.isEmpty) {
    start = max(0, length - int.parse(b));
    end = length - 1;
  } else {
    start = int.parse(a);
    end = b.isEmpty ? length - 1 : min(int.parse(b), length - 1);
  }
  if (start > end || start >= length) return null;
  return (start, end);
}

/// Image content type from the file's first bytes (embedded art is stored
/// with a generic `.img` name), or null if it is not a known image format.
String? sniffImageType(List<int> b) {
  bool at(int i, List<int> m) => b.length >= i + m.length && [for (var k = 0; k < m.length; k++) b[i + k] == m[k]].every((x) => x);
  if (at(0, [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (at(0, [0x89, 0x50, 0x4e, 0x47])) return 'image/png';
  if (at(0, [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return 'image/webp';
  if (at(0, [0x42, 0x4d])) return 'image/bmp';
  return null;
}

class _Asset {
  _Asset({this.path, this.bytes, required this.type});
  final String? path;
  final List<int>? bytes;
  final String type;
}

/// Serves registered audio files, cover art and caption text over HTTP (with
/// Range support) so a Cast device on the LAN can fetch them. Each asset gets
/// an unguessable URL; nothing else is reachable.
class CastMediaServer {
  HttpServer? _server;
  final _assets = <String, _Asset>{};
  final _byKey = <String, String>{};
  final _rand = Random.secure();

  Future<void> start() async {
    if (_server != null) return;
    final s = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = s;
    s.listen(_handle, onError: (_) {});
  }

  String _register(String key, String name, String host, _Asset Function() make) {
    final token = _byKey.putIfAbsent(key, () {
      final t = List.generate(16, (_) => _rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      _assets[t] = make();
      return t;
    });
    return 'http://$host:${_server!.port}/m/$token/${Uri.encodeComponent(name)}';
  }

  /// URL at which a device that reaches us as [host] can fetch the audio file [path].
  String urlFor(String path, String host) =>
      _register('a:$path', p.basename(path), host, () => _Asset(path: path, type: castContentType(path)));

  /// URL for the cover image file [path], or null if it is not a known image.
  Future<String?> imageUrl(String path, String host) async {
    final key = 'i:$path';
    if (!_byKey.containsKey(key)) {
      try {
        final f = File(path);
        if (!await f.exists()) return null;
        final head = await f.openRead(0, 16).expand((b) => b).toList();
        final type = sniffImageType(head);
        if (type == null) return null;
        return _register(key, 'cover', host, () => _Asset(path: path, type: type));
      } catch (_) {
        return null;
      }
    }
    return _register(key, 'cover', host, () => throw StateError('registered'));
  }

  /// URL for in-memory text such as captions. [key] identifies the content.
  String textUrl(String key, String text, String type, String host, {String name = 'text'}) =>
      _register('t:$key', name, host, () => _Asset(bytes: utf8.encode(text), type: type));

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Headers', 'Range');
    res.headers.set('Access-Control-Expose-Headers', 'Content-Range, Accept-Ranges, Content-Length');
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
        return;
      }
      final segs = req.uri.pathSegments;
      final asset = segs.length >= 2 && segs[0] == 'm' ? _assets[segs[1]] : null;
      final file = asset?.path == null ? null : File(asset!.path!);
      if (asset == null || (file != null && !await file.exists())) {
        res.statusCode = HttpStatus.notFound;
        return;
      }
      final length = file != null ? await file.length() : asset.bytes!.length;
      final range = parseByteRange(req.headers.value(HttpHeaders.rangeHeader), length);
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..contentType = ContentType.parse(asset.type);
      if (req.headers.value(HttpHeaders.rangeHeader) != null && range == null) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        return;
      }
      final (start, end) = range ?? (0, length - 1);
      if (range != null) {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      }
      res.contentLength = length == 0 ? 0 : end - start + 1;
      if (req.method == 'HEAD' || length == 0) return;
      if (file != null) {
        await res.addStream(file.openRead(start, end + 1));
      } else {
        res.add(asset.bytes!.sublist(start, end + 1));
      }
    } catch (_) {
      // The device closed the connection (seek or skip); nothing to do.
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _assets.clear();
    _byKey.clear();
    await s?.close(force: true);
  }
}
