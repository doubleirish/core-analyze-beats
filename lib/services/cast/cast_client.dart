import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cast_protocol.dart';

const _nsConnection = 'urn:x-cast:com.google.cast.tp.connection';
const _nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
const _nsReceiver = 'urn:x-cast:com.google.cast.receiver';
const _nsMedia = 'urn:x-cast:com.google.cast.media';

/// The Default Media Receiver app built into every Cast device.
const defaultMediaReceiverId = 'CC1AD845';

class CastException implements Exception {
  CastException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// State of the media on the receiver, from a MEDIA_STATUS message.
class CastMediaStatus {
  const CastMediaStatus({
    required this.mediaSessionId,
    required this.playerState,
    required this.currentTime,
    this.duration,
    this.idleReason,
  });

  final int mediaSessionId;

  /// IDLE, PLAYING, PAUSED or BUFFERING.
  final String playerState;
  final double currentTime;
  final double? duration;
  final String? idleReason;

  static CastMediaStatus? fromJson(Map<String, dynamic> j) {
    final list = j['status'];
    if (list is! List || list.isEmpty || list.first is! Map) return null;
    final s = (list.first as Map).cast<String, dynamic>();
    final id = s['mediaSessionId'];
    if (id is! int) return null;
    final media = s['media'];
    return CastMediaStatus(
      mediaSessionId: id,
      playerState: s['playerState'] as String? ?? 'IDLE',
      currentTime: (s['currentTime'] as num?)?.toDouble() ?? 0,
      duration: media is Map ? (media['duration'] as num?)?.toDouble() : null,
      idleReason: s['idleReason'] as String?,
    );
  }
}

/// Minimal Cast v2 sender: connects to a device, launches the Default Media
/// Receiver and controls playback of a URL.
class CastClient {
  CastClient(this.host, {this.port = 8009});

  final String host;
  final int port;

  static const _sender = 'sender-0';
  static const _receiver = 'receiver-0';

  SecureSocket? _socket;
  Timer? _heartbeat;
  DateTime _lastSeen = DateTime.now();
  int _requestId = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _status = StreamController<CastMediaStatus>.broadcast();
  final _closed = Completer<Object?>();
  String? _transportId;
  String? _sessionId;
  int? _mediaSessionId;

  /// Local address the device can reach us on: our interface address on the
  /// device's subnet, else the first non-loopback IPv4 address.
  Future<String> findLocalAddress() async {
    final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    final addrs = [for (final i in ifaces) ...i.addresses.where((a) => !a.isLoopback)];
    final prefix = host.split('.').take(3).join('.');
    for (final a in addrs) {
      if (a.address.split('.').take(3).join('.') == prefix) return a.address;
    }
    if (addrs.isEmpty) throw CastException('No network connection');
    return addrs.first.address;
  }

  Stream<CastMediaStatus> get status => _status.stream;

  /// Completes when the connection ends; with an error object if it failed.
  Future<Object?> get closed => _closed.future;

  bool get isOpen => !_closed.isCompleted;

  Future<void> connect() async {
    final s = await SecureSocket.connect(host, port,
        onBadCertificate: (_) => true, timeout: const Duration(seconds: 6));
    _socket = s;
    final reader = CastFrameReader();
    s.listen(
      (chunk) {
        _lastSeen = DateTime.now();
        for (final m in reader.add(chunk)) {
          _onMessage(m);
        }
      },
      onError: (Object e) => _close(e),
      onDone: () => _close(null),
      cancelOnError: true,
    );
    _send(_nsConnection, _receiver, {'type': 'CONNECT'});
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(_lastSeen) > const Duration(seconds: 20)) {
        _close(CastException('The device stopped responding'));
        return;
      }
      _send(_nsHeartbeat, _receiver, {'type': 'PING'});
    });
  }

  void _send(String ns, String dest, Map<String, dynamic> payload) {
    final s = _socket;
    if (s == null || !isOpen) throw CastException('Not connected');
    s.add(encodeCastFrame(CastMessage(
        sourceId: _sender, destinationId: dest, namespace: ns, payload: jsonEncode(payload))));
  }

  Future<Map<String, dynamic>> _request(String ns, String dest, Map<String, dynamic> payload) {
    final id = ++_requestId;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _send(ns, dest, {...payload, 'requestId': id});
    return c.future.timeout(const Duration(seconds: 12), onTimeout: () {
      _pending.remove(id);
      throw CastException('The device did not answer');
    });
  }

  void _onMessage(CastMessage m) {
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(m.payload) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    final type = j['type'];
    if (m.namespace == _nsHeartbeat) {
      if (type == 'PING') _send(_nsHeartbeat, m.sourceId, {'type': 'PONG'});
      return;
    }
    if (m.namespace == _nsConnection && type == 'CLOSE') {
      _close(m.sourceId == _transportId ? CastException('The cast app was closed') : null);
      return;
    }
    if (m.namespace == _nsMedia && type == 'MEDIA_STATUS') {
      final st = CastMediaStatus.fromJson(j);
      if (st != null && !_status.isClosed) _status.add(st);
    }
    final id = j['requestId'];
    if (id is int && id != 0) _pending.remove(id)?.complete(j);
  }

  /// Launches the Default Media Receiver (or joins it if already running).
  Future<void> launch() async {
    final reply = await _request(_nsReceiver, _receiver,
        {'type': 'LAUNCH', 'appId': defaultMediaReceiverId});
    if (reply['type'] == 'LAUNCH_ERROR') {
      throw CastException('The device refused to start its media player');
    }
    final apps = (reply['status'] as Map?)?['applications'];
    final app = apps is List
        ? apps.whereType<Map>().firstWhere(
            (a) => a['appId'] == defaultMediaReceiverId && a['transportId'] != null,
            orElse: () => const {})
        : const {};
    if (app['transportId'] == null) throw CastException('The media player did not start');
    _transportId = app['transportId'] as String;
    _sessionId = app['sessionId'] as String?;
    _send(_nsConnection, _transportId!, {'type': 'CONNECT'});
  }

  /// Loads [url] and returns its first status.
  Future<CastMediaStatus?> load(
    String url, {
    required String contentType,
    String? title,
    String? artist,
    String? album,
    String? imageUrl,
    String? captionsUrl,
    double startSec = 0,
    bool autoplay = true,
  }) async {
    final t = _transportId;
    if (t == null) throw CastException('No media player running');
    _mediaSessionId = null;
    final reply = await _request(_nsMedia, t, {
      'type': 'LOAD',
      'autoplay': autoplay,
      'currentTime': startSec,
      if (captionsUrl != null) 'activeTrackIds': [1],
      'media': {
        'contentId': url,
        'contentType': contentType,
        'streamType': 'BUFFERED',
        if (captionsUrl != null)
          'tracks': [
            {
              'trackId': 1,
              'type': 'TEXT',
              'subtype': 'SUBTITLES',
              'trackContentId': captionsUrl,
              'trackContentType': 'text/vtt',
              'name': 'Lyrics',
              'language': 'en',
            }
          ],
        'metadata': {
          'metadataType': 3,
          'title': ?title,
          'artist': ?artist,
          'albumName': ?album,
          if (imageUrl != null) 'images': [{'url': imageUrl}],
        },
      },
    });
    final type = reply['type'];
    if (type == 'LOAD_FAILED' || type == 'INVALID_REQUEST') {
      throw CastException('The device could not play this file');
    }
    final st = CastMediaStatus.fromJson(reply);
    _mediaSessionId = st?.mediaSessionId;
    return st;
  }

  Future<void> _control(String type, [Map<String, dynamic> extra = const {}]) async {
    final t = _transportId, id = _mediaSessionId;
    if (t == null || id == null) return;
    await _request(_nsMedia, t, {'type': type, 'mediaSessionId': id, ...extra});
  }

  Future<void> play() => _control('PLAY');
  Future<void> pause() => _control('PAUSE');
  Future<void> seek(double sec, {bool resume = true}) =>
      _control('SEEK', {'currentTime': sec, if (resume) 'resumeState': 'PLAYBACK_START'});

  /// Asks the receiver for the current status (it only pushes changes).
  void refresh() {
    final t = _transportId;
    if (t == null || !isOpen) return;
    try {
      _send(_nsMedia, t, {'type': 'GET_STATUS', 'requestId': ++_requestId});
    } catch (_) {}
  }

  /// Stops the receiver app and closes the connection.
  Future<void> close() async {
    final sid = _sessionId;
    if (sid != null && isOpen) {
      try {
        _send(_nsReceiver, _receiver, {'type': 'STOP', 'sessionId': sid, 'requestId': ++_requestId});
        await _socket!.flush();
      } catch (_) {}
    }
    _close(null);
  }

  void _close(Object? error) {
    if (_closed.isCompleted) return;
    _closed.complete(error);
    _heartbeat?.cancel();
    for (final c in _pending.values) {
      c.completeError(CastException('Connection closed'));
    }
    _pending.clear();
    _socket?.destroy();
    _status.close();
  }
}
