import 'dart:async';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';

/// Equal-power crossfade gains for progress [t] in 0..1: (outgoing, incoming).
(double, double) fadeGains(double t) {
  final x = t.clamp(0.0, 1.0);
  return (math.cos(x * math.pi / 2), math.sin(x * math.pi / 2));
}

/// What the engine plays: a file, optionally clipped to [start]..[end]
/// (seconds into the file), at a volume [gain] (0..1) that evens out
/// loudness between songs. Positions and durations reported for a clipped
/// track are relative to [start].
class EngineTrack {
  const EngineTrack(this.path, {this.start, this.end, this.gain = 1});
  final String path;
  final double? start, end;
  final double gain;

  bool get clipped => (start ?? 0) > 0 || end != null;

  @override
  bool operator ==(Object other) =>
      other is EngineTrack &&
      other.path == path &&
      other.start == start &&
      other.end == end &&
      other.gain == gain;
  @override
  int get hashCode => Object.hash(path, start, end, gain);
}

/// A device that plays songs instead of the local players (e.g. a Chromecast).
/// Positions and durations are in file time, like [PlayerEngine.position].
abstract class RemoteRenderer {
  Duration get position;
  Duration? get duration;
  bool get playing;

  /// Called once when the loaded song played to its end.
  void Function()? onEnded;

  /// Called when the device failed or went away.
  void Function(Object error)? onError;

  /// Loads [t], seeking to [at] (file time), and starts it when [play].
  Future<void> load(EngineTrack t, {Duration? at, bool play = true});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration d);

  /// Stops playback and releases the device.
  Future<void> stop();
}

/// Two alternating players so the next song can be pre-loaded (gapless) or
/// overlapped with the current one (crossfade). While a [RemoteRenderer] is
/// set, playback goes there instead and crossfade, loudness gain and the
/// trimmed-end fade are not applied.
class PlayerEngine {
  PlayerEngine() {
    _wire(_a);
    _wire(_b);
    _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => _tick());
  }

  final AudioPlayer _a = AudioPlayer();
  final AudioPlayer _b = AudioPlayer();
  late AudioPlayer _active = _a;
  AudioPlayer get _idle => identical(_active, _a) ? _b : _a;
  Timer? _timer;

  /// false = gapless (pre-load, no overlap), true = overlap by [fadeSec].
  bool crossfade = false;
  double fadeSec = 4;

  /// Called after playback moved on to the pre-loaded next song by itself.
  void Function()? onAdvanced;

  /// Called when a song finished and no next song was pre-loaded.
  void Function()? onEnded;

  /// Called after a sleep-timer fade-out paused playback.
  void Function()? onStopped;

  /// Fades out and pauses at the end of the current song instead of moving on.
  bool stopAtSongEnd = false;
  static const stopFadeSec = 8.0;
  bool _stopping = false;
  double _stopLen = 0;
  DateTime _stopEnd = DateTime.now();

  /// How late the local output is heard (e.g. Bluetooth). Reported positions
  /// are held back by this much so visuals line up with what is heard.
  Duration outputDelay = Duration.zero;

  RemoteRenderer? _remote;
  EngineTrack? _rTrack;
  bool _rEnding = false;
  bool _rPlaying = false;

  /// True while playing on a [RemoteRenderer].
  bool get isRemote => _remote != null;

  EngineTrack? _nextPath;
  EngineTrack? _preloaded;

  /// Loudness gain and trim of the track loaded in each player.
  final Map<AudioPlayer, EngineTrack> _loaded = {};
  double _gain(AudioPlayer p) => _loaded[p]?.gain ?? 1;

  /// Sets [p]'s volume to [v] scaled by its track's loudness gain.
  Future<void> _vol(AudioPlayer p, double v) => p.setVolume((v * _gain(p)).clamp(0.0, 1.0));

  /// Seconds faded out before a trimmed end, so the cut isn't abrupt.
  static const trimFadeSec = 1.5;

  Future<void> _open(AudioPlayer p, EngineTrack t) async {
    final src = AudioSource.file(t.path);
    await p.setAudioSource(t.clipped
        ? ClippingAudioSource(
            child: src,
            start: t.start == null ? null : Duration(milliseconds: (t.start! * 1000).round()),
            end: t.end == null ? null : Duration(milliseconds: (t.end! * 1000).round()))
        : src);
    _loaded[p] = t;
  }
  int _preloadGen = 0;
  bool _fading = false;
  double _fadeLen = 0;

  final _pos = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _state = StreamController<ProcessingState>.broadcast();

  Stream<Duration> get positionStream => _pos.stream;
  Stream<bool> get playingStream => _playing.stream;
  Stream<ProcessingState> get processingStateStream => _state.stream;

  /// Where the current track's clip starts in its file (seconds). Positions
  /// and durations are reported in file time, so tempo maps, waveforms and
  /// beat clicks line up; plans timed from the clip start subtract this.
  double get clipStart => (_remote != null ? _rTrack : _loaded[_active])?.start ?? 0;
  Duration _offset(AudioPlayer p) => Duration(milliseconds: (((_loaded[p]?.start) ?? 0) * 1000).round());

  Duration get _rawPosition => _remote?.position ?? _active.position + _offset(_active);

  Duration get position => _seen(_rawPosition);

  /// [d] held back by [outputDelay] for local output.
  Duration _seen(Duration d) {
    if (_remote != null || outputDelay == Duration.zero) return d;
    final v = d - outputDelay;
    return v.isNegative ? Duration.zero : v;
  }

  /// File time at which the current track stops (its trimmed end).
  Duration? get duration {
    final r = _remote;
    if (r != null) {
      final end = _rTrack?.end;
      return end != null ? Duration(milliseconds: (end * 1000).round()) : r.duration;
    }
    final d = _active.duration;
    return d == null ? null : d + _offset(_active);
  }
  bool get playing => _remote?.playing ?? _active.playing;
  ProcessingState get processingState => _active.processingState;

  void _wire(AudioPlayer p) {
    p.positionStream.listen((d) {
      if (identical(p, _active) && _remote == null) _pos.add(_seen(d + _offset(p)));
    });
    p.playingStream.listen((v) {
      if (identical(p, _active) && _remote == null) _playing.add(v);
    });
    p.processingStateStream.listen((s) {
      if (!identical(p, _active) || _remote != null) return;
      _state.add(s);
      if (s == ProcessingState.completed) _completed();
    });
  }

  void _emitActive() {
    _pos.add(position);
    _playing.add(playing);
    _state.add(_active.processingState);
  }

  /// Moves playback to [r] (null = back to the local players), carrying the
  /// current song and position across. If [r] fails to start, playback stays
  /// where it was and the error is rethrown.
  Future<void> useRemote(RemoteRenderer? r) async {
    if (identical(r, _remote)) return;
    final old = _remote;
    final track = old != null ? _rTrack : _loaded[_active];
    final at = _rawPosition;
    final wasPlaying = playing;
    _cancelFade();
    _cancelStop();
    if (old == null) {
      await _a.pause();
      await _b.pause();
    }
    if (r != null) {
      _preloaded = null;
      ++_preloadGen;
      r.onEnded = _remoteEnded;
      try {
        if (track != null) await r.load(track, at: at, play: wasPlaying);
      } catch (_) {
        r.onEnded = null;
        if (old == null && wasPlaying) unawaited(_active.play());
        rethrow;
      }
    }
    _remote = r;
    _rTrack = r == null ? null : track;
    _rEnding = false;
    _rPlaying = r?.playing ?? false;
    if (old != null) {
      old.onEnded = null;
      unawaited(old.stop().catchError((_) {}));
    }
    if (r == null && track != null) {
      await _open(_active, track);
      await _vol(_active, 1);
      final c = at - _offset(_active);
      await _active.seek(c.isNegative ? Duration.zero : c);
      if (wasPlaying) unawaited(_active.play());
      unawaited(setNext(_nextPath));
    }
    _emitActive();
  }

  Future<void> _remoteEnded() async {
    if (_remote == null || _rEnding) return;
    _rEnding = true;
    final n = _nextPath;
    if (n == null) {
      onEnded?.call();
      return;
    }
    _nextPath = null;
    try {
      await load(n);
      onAdvanced?.call();
    } catch (_) {
      onEnded?.call();
    }
  }

  void _remoteTick(RemoteRenderer r) {
    final pl = r.playing;
    if (pl != _rPlaying) {
      _rPlaying = pl;
      _playing.add(pl);
    }
    if (!pl) return;
    final pos = r.position;
    _pos.add(pos);
    if (_rEnding) return;
    final endSec = _rTrack?.end;
    final end = endSec != null ? Duration(milliseconds: (endSec * 1000).round()) : r.duration;
    if (end == null || end == Duration.zero) return;
    if (stopAtSongEnd && end - pos <= const Duration(milliseconds: 400)) {
      stopAtSongEnd = false;
      unawaited(r.pause());
      onStopped?.call();
    } else if (endSec != null && pos >= end) {
      unawaited(_remoteEnded());
    }
  }

  /// Starts [path] immediately (hard cut).
  Future<void> load(EngineTrack path) async {
    final r = _remote;
    if (r != null) {
      _rTrack = path;
      _rEnding = false;
      await r.load(path, at: path.start == null ? null : Duration(milliseconds: (path.start! * 1000).round()));
      _rPlaying = r.playing;
      _emitActive();
      return;
    }
    _cancelFade();
    _cancelStop();
    final idle = _idle;
    if (_preloaded == path) {
      final old = _active;
      _active = idle;
      _preloaded = null;
      await old.pause();
      await _vol(_active, 1);
      await _active.seek(Duration.zero);
      unawaited(_active.play());
      _emitActive();
      return;
    }
    await _open(_active, path);
    await _vol(_active, 1);
    unawaited(_active.play());
  }

  /// Tells the engine which song follows, pre-loading it into the idle player.
  Future<void> setNext(EngineTrack? path) async {
    _nextPath = path;
    if (_fading || _remote != null) return;
    final gen = ++_preloadGen;
    if (path == null) {
      _preloaded = null;
      return;
    }
    if (_preloaded == path) return;
    _preloaded = null;
    try {
      final idle = _idle;
      await idle.setVolume(0);
      await _open(idle, path);
      if (gen == _preloadGen && !_fading) _preloaded = path;
    } catch (_) {
      _preloaded = null;
    }
  }

  Future<void> play() async {
    final r = _remote;
    if (r != null) return r.play();
    if (_fading) unawaited(_idle.play());
    await _active.play();
  }

  Future<void> pause() async {
    final r = _remote;
    if (r != null) return r.pause();
    if (_fading) unawaited(_idle.pause());
    await _active.pause();
  }

  Future<void> seek(Duration d) async {
    if (_disposed) return;
    final r = _remote;
    if (r != null) {
      await r.seek(d);
      _pos.add(d);
      return;
    }
    try {
      final c = d - _offset(_active);
      await _active.seek(c.isNegative ? Duration.zero : c);
    } catch (_) {
      if (!_disposed) rethrow;
    }
  }

  bool get _ready => _preloaded != null && _preloaded == _nextPath;

  /// Fades the volume to silence over [seconds], then pauses and restores it.
  void fadeOutAndPause(double seconds) {
    final r = _remote;
    if (r != null) {
      stopAtSongEnd = false;
      unawaited(r.pause());
      onStopped?.call();
      return;
    }
    if (_stopping) return;
    if (_fading) {
      _finishStop();
      return;
    }
    _stopping = true;
    _stopLen = math.max(seconds, 0.2);
    _stopEnd = DateTime.now().add(Duration(milliseconds: (_stopLen * 1000).round()));
  }

  void _cancelStop() {
    if (!_stopping) return;
    _stopping = false;
    unawaited(_vol(_active, 1));
  }

  void _finishStop() {
    _stopping = false;
    stopAtSongEnd = false;
    unawaited(_active.pause());
    unawaited(_vol(_active, 1));
    unawaited(_idle.pause());
    onStopped?.call();
  }

  void _tick() {
    final r = _remote;
    if (r != null) {
      _remoteTick(r);
      return;
    }
    final a = _active;
    if (!a.playing) return;
    if (_stopping) {
      final left = _stopEnd.difference(DateTime.now()).inMilliseconds / 1000;
      if (left <= 0) {
        _finishStop();
      } else {
        unawaited(_vol(a, (left / _stopLen).clamp(0.0, 1.0)));
      }
      return;
    }
    final dur = a.duration;
    if (dur == null || dur == Duration.zero) return;
    final remaining = (dur - a.position).inMilliseconds / 1000;
    if (stopAtSongEnd && !_fading && remaining <= stopFadeSec + 0.3) {
      fadeOutAndPause(remaining - 0.3);
      return;
    }
    if (_fading) {
      _stepFade(remaining);
      return;
    }
    // A trimmed end fades out briefly instead of cutting mid-phrase.
    final cutEnd = _loaded[a]?.end != null && !(crossfade && _ready && fadeSec >= 1);
    if (cutEnd && remaining <= trimFadeSec) {
      unawaited(_vol(a, (remaining / trimFadeSec).clamp(0.0, 1.0)));
    }
    if (!_ready) {
      return;
    } else if (crossfade && fadeSec >= 1 && dur.inMilliseconds / 1000 > fadeSec * 2) {
      if (remaining <= fadeSec) _startFade(remaining);
    } else if (remaining <= 0.04) {
      _advance();
    }
  }

  void _startFade(double remaining) {
    _fading = true;
    _fadeLen = math.max(remaining, 0.1);
    final idle = _idle;
    unawaited(idle.setVolume(0));
    unawaited(idle.play());
  }

  void _stepFade(double remaining) {
    final t = 1 - remaining / _fadeLen;
    final g = fadeGains(t);
    unawaited(_vol(_active, g.$1));
    unawaited(_vol(_idle, g.$2));
    if (t >= 1 || remaining <= 0.05) _advance();
  }

  void _cancelFade() {
    if (!_fading) return;
    _fading = false;
    unawaited(_idle.pause());
    unawaited(_idle.setVolume(0));
    unawaited(_vol(_active, 1));
    _preloaded = null;
  }

  /// Makes the pre-loaded player the active one.
  void _advance() {
    if (!_ready) return;
    final old = _active;
    final next = _idle;
    _active = next;
    _fading = false;
    _preloaded = null;
    _nextPath = null;
    unawaited(_vol(next, 1));
    unawaited(next.play());
    unawaited(old.pause());
    _emitActive();
    final stop = stopAtSongEnd;
    onAdvanced?.call();
    if (stop) _finishStop();
  }

  void _completed() {
    if (_ready) {
      _advance();
    } else {
      onEnded?.call();
    }
  }

  bool _disposed = false;

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    final r = _remote;
    _remote = null;
    if (r != null) unawaited(r.stop().catchError((_) {}));
    await _pos.close();
    await _playing.close();
    await _state.close();
    await _a.dispose();
    await _b.dispose();
  }
}
