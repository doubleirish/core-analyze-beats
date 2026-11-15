import 'dart:async';
import 'dart:io';

import '../../models/lyrics.dart';
import '../player_engine.dart';
import 'cast_client.dart';
import 'cast_discovery.dart';
import 'cast_media_server.dart';
import 'lyrics_vtt.dart';

/// Song details shown on the cast device: text, cover image and (timed) lyrics.
typedef CastTrackInfo = ({String? title, String? artist, String? album, File? art, Lyrics? lyrics});

/// Plays on a Cast device: connects, serves the files over HTTP and mirrors the
/// receiver's state so the engine sees a normal position/playing/ended.
class CastRenderer extends RemoteRenderer {
  CastRenderer(this.device, {this.info});

  final CastDevice device;
  final Future<CastTrackInfo> Function(String path)? info;

  final _server = CastMediaServer();
  CastClient? _client;
  StreamSubscription<CastMediaStatus>? _sub;
  Timer? _poll;

  int? _mediaSession;
  bool _playing = false, _running = false;
  Duration _base = Duration.zero;
  DateTime _baseAt = DateTime.now();
  Duration? _duration;
  bool _stopped = false;

  @override
  bool get playing => _playing;

  @override
  Duration? get duration => _duration;

  @override
  Duration get position {
    if (!_running) return _base;
    final p = _base + DateTime.now().difference(_baseAt);
    final d = _duration;
    return d != null && p > d ? d : p;
  }

  Future<void> _ensureConnected() async {
    if (_client != null && _client!.isOpen) return;
    final c = CastClient(device.host, port: device.port);
    await c.connect();
    try {
      await _server.start();
      await c.launch();
    } catch (_) {
      await c.close();
      rethrow;
    }
    _client = c;
    _sub = c.status.listen(_onStatus);
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => c.refresh());
    unawaited(c.closed.then((err) {
      if (_stopped || !identical(_client, c)) return;
      _playing = false;
      _running = false;
      onError?.call(err ?? CastException('${device.name} disconnected'));
    }));
  }

  void _setBase(double sec, {required bool running}) {
    _base = Duration(milliseconds: (sec * 1000).round());
    _baseAt = DateTime.now();
    _running = running;
  }

  void _onStatus(CastMediaStatus s) {
    if (_mediaSession == null) {
      // Ignore leftovers from the previous song until the new one reports in.
      if (s.playerState == 'IDLE') return;
      _mediaSession = s.mediaSessionId;
    } else if (s.mediaSessionId != _mediaSession) {
      return;
    }
    if (s.duration != null) _duration = Duration(milliseconds: (s.duration! * 1000).round());
    switch (s.playerState) {
      case 'PLAYING':
        _playing = true;
        _setBase(s.currentTime, running: true);
      case 'BUFFERING':
        _playing = true;
        _setBase(s.currentTime, running: false);
      case 'PAUSED':
        _playing = false;
        _setBase(s.currentTime, running: false);
      case 'IDLE':
        _playing = false;
        _running = false;
        if (s.idleReason == 'FINISHED') {
          if (_duration != null) _base = _duration!;
          onEnded?.call();
        } else if (s.idleReason == 'ERROR') {
          onError?.call(CastException('${device.name} could not play this song'));
        }
    }
  }

  @override
  Future<void> load(EngineTrack t, {Duration? at, bool play = true}) async {
    await _ensureConnected();
    final c = _client!;
    CastTrackInfo? meta;
    try {
      meta = await info?.call(t.path);
    } catch (_) {
      // Missing details never stop the music.
    }
    final host = await c.findLocalAddress();
    String? image, captions;
    final vtt = lyricsToVtt(meta?.lyrics);
    try {
      if (meta?.art != null) image = await _server.imageUrl(meta!.art!.path, host);
      if (vtt != null) captions = _server.textUrl('${t.path}:${vtt.hashCode}', vtt, 'text/vtt', host, name: 'lyrics.vtt');
    } catch (_) {}
    final start = (at ?? Duration.zero).inMilliseconds / 1000;
    _mediaSession = null;
    _duration = null;
    _setBase(start, running: false);
    _playing = play;
    final st = await c.load(
      _server.urlFor(t.path, host),
      contentType: castContentType(t.path),
      title: meta?.title,
      artist: meta?.artist,
      album: meta?.album,
      imageUrl: image,
      captionsUrl: captions,
      startSec: start,
      autoplay: play,
    );
    if (st != null && st.playerState != 'IDLE') _onStatus(st);
  }

  @override
  Future<void> play() async {
    _playing = true;
    _setBase(position.inMilliseconds / 1000, running: true);
    await _client?.play();
  }

  @override
  Future<void> pause() async {
    final p = position;
    _playing = false;
    _setBase(p.inMilliseconds / 1000, running: false);
    await _client?.pause();
  }

  @override
  Future<void> seek(Duration d) async {
    _setBase(d.inMilliseconds / 1000, running: _playing);
    await _client?.seek(d.inMilliseconds / 1000, resume: _playing);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _poll?.cancel();
    await _sub?.cancel();
    final c = _client;
    _client = null;
    _playing = false;
    _running = false;
    await c?.close();
    await _server.stop();
  }
}
