import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/gear.dart';
import '../models/media.dart';
import '../models/step_plan.dart';
import '../models/tempo.dart';
import 'algorithms.dart';
import 'bpm_analyzer.dart';
import 'bpm_store.dart';
import 'enrich_service.dart';
import 'keep_screen_on.dart';
import 'library_service.dart';
import 'loudness.dart';
import 'metronome.dart';
import 'mixtape/importer.dart' show SongMeta;
import 'player_engine.dart';
import 'queue_service.dart';
import 'spectrum.dart';
import 'tags.dart';
import 'transition_alerts.dart';
import 'waveform.dart';

/// Playback, tempo/waveform/spectrum lookups, art and lyrics for the current
/// song: everything the now-playing UI needs, identical in both apps.
/// Apps supply the song lists and react to plays through the hooks below.
/// What the sleep timer waits for before fading out and pausing.
enum StopMode { none, minutes, endOfSong, endOfMix }

abstract class PlaybackController extends ChangeNotifier {
  PlaybackController({required this.appId, Random? random}) : random = random ?? Random();

  /// Used to name temp files (click track, extracted art).
  final String appId;
  @protected
  final Random random;

  late final PlayerEngine player = PlayerEngine();
  final QueueService _queueService = QueueService();
  SharedPreferences? _prefs;
  bool _playbackReady = false;

  /// Preferences, available after [initPlayback].
  @protected
  SharedPreferences? get prefs => _prefs;

  /// Songs available to play in alphabetical/shuffle modes.
  List<String> get libraryPaths;

  /// The mix, in order, for [PlayMode.mix].
  List<String> get mixPaths;

  /// Called when a song stopped being listened to; [listened] is seconds.
  @protected
  void onPlayFinished(String path, double listened, bool completed) {}

  /// Called before the user starts something new (not for auditions).
  @protected
  void onPlayStarting() {}

  PlayMode mode = PlayMode.alphabetical;
  List<String> queue = [];
  int index = -1;
  String? error;
  bool repeat = false;
  String algorithm = baselineId;
  bool skipSilence = true;

  final Map<String, TempoResults?> tempos = {};
  final Set<String> analyzing = {};
  final Map<String, TrackMedia> media = {};
  final Set<String> _loadingMedia = {};
  final Set<String> fetching = {};
  final EnrichService enricher = EnrichService();
  String? enrichNote;

  /// Program/class part (e.g. "Climb") of the current song, and the next
  /// upcoming part that differs from it; null when the mix has no program.
  String? currentStep;
  String? nextStep;

  /// Timed sub-activities of the current song and of the next song in the
  /// queue ([nextSongPlan]) / next song whose activity differs ([nextPlan]).
  StepPlan? currentPlan;
  StepPlan? nextSongPlan;

  /// Plan of the song before the current one in the queue.
  StepPlan? prevPlan;

  /// Whether the instructor's current advice is spoken aloud.
  bool speakAdvice = false;
  void setSpeakAdvice(bool v) {
    speakAdvice = v;
    _prefs?.setBool('speakAdvice', v);
    notifyListeners();
  }
  StepPlan? nextPlan;

  /// The rider's base gear; a program part's own base gear wins over it.
  int baseGear = 12;
  GearScale gearScale = GearScale.keiser;
  void setBaseGear(int g) {
    baseGear = gearScale.clamp(g);
    _prefs?.setInt('baseGear', baseGear);
    notifyListeners();
  }

  void nudgeBaseGear(int by) => setBaseGear(baseGear + by);

  /// The gear to call out for [seg] of [plan], or null when it has none.
  GearCall? gearAt(StepPlan? plan, StepSegment? seg) =>
      gearCall(plan?.baseGear ?? baseGear, seg?.gear, gearScale);

  /// The next (up to 3) main activities after the current one, in order.
  List<UpcomingStep> upcomingSteps = const [];

  /// Every activity of the queue on one clock, and where the current song
  /// starts on it, for the whole-mix progress bar. Empty without a program.
  List<MixBlock> mixBlocks = const [];
  double mixSongStart = 0;
  double mixTotalSeconds = 0;
  int get mixBlockIndex {
    for (var i = 0; i < mixBlocks.length; i++) {
      if (index >= mixBlocks[i].firstSong && index < mixBlocks[i].firstSong + mixBlocks[i].songs) {
        return i;
      }
    }
    return -1;
  }
  final Map<String, String?> _stepCache = {};
  final Map<String, StepPlan?> _planCache = {};

  Set<String> hiddenViews = {};

  /// Loads saved playback preferences and wires the engine; call once at start-up.
  Future<void> initPlayback() async {
    final p = _prefs = await SharedPreferences.getInstance();
    _playbackReady = true;
    mode = PlayMode.values[(p.getInt('mode') ?? 0) % PlayMode.values.length];
    repeat = p.getBool('repeat') ?? false;
    skipSilence = p.getBool('skipSilence') ?? true;
    speakAdvice = p.getBool('speakAdvice') ?? false;
    baseGear = gearScale.clamp(p.getInt('baseGear') ?? 12);
    keepScreenOn = p.getBool('keepScreenOn') ?? true;
    final savedAlgo = p.getString('algo');
    if (savedAlgo != null && algorithmById(savedAlgo) != null) algorithm = savedAlgo;
    enricher.disabledSources = (p.getStringList('lyricsOff') ?? []).toSet();
    enricher.geniusToken = p.getString('geniusToken');
    hiddenViews = (p.getStringList('npHidden') ?? []).toSet();
    // 'viewsInit' was analyze-this's single first-run flag.
    final legacyInit = p.getBool('viewsInit') ?? false;
    var changed = false;
    if (!legacyInit && !(p.getBool('spectrumInit') ?? false)) {
      hiddenViews.add('spectrum');
      changed = true;
    }
    if (!legacyInit && !(p.getBool('metroInit') ?? false)) {
      hiddenViews.addAll(['beat', 'click']);
      changed = true;
    }
    if (changed) p.setStringList('npHidden', hiddenViews.toList());
    p.setBool('spectrumInit', true);
    p.setBool('metroInit', true);
    player.playingStream.listen((_) {
      unawaited(_syncClicker());
      _syncKeepScreenOn();
    });
    player.crossfade = p.getBool('xfade') ?? false;
    levelLoudness = p.getBool('levelLoudness') ?? true;
    player.fadeSec = p.getDouble('xfadeSec') ?? 4;
    player.onEnded = playNext;
    player.onAdvanced = _onAdvanced;
    player.onStopped = _onStopped;
    alerts = (p.getStringList('alerts') ?? const ['flash', 'vibrate']).where(alertTypes.contains).toSet();
    player.positionStream.listen(_alertTick);
    notifyListeners();
  }

  // ---- tempo ----

  TempoMap? mapOf(String? path) => path == null ? null : tempos[path]?.mapFor(algorithm);

  bool isComplete(TempoResults? r) =>
      r != null && allAlgorithms.every((a) => r.byAlgo.containsKey(a.id));

  void setAlgorithm(String id) {
    algorithm = id;
    _prefs?.setString('algo', id);
    notifyListeners();
  }

  Future<TempoResults?> tempoFor(String path) async {
    if (!tempos.containsKey(path)) tempos[path] = await BpmStore.load(path);
    return tempos[path];
  }

  Future<void> analyze(String path) async {
    if (analyzing.contains(path)) return;
    analyzing.add(path);
    error = null;
    notifyListeners();
    try {
      final map = await analyzeFile(path);
      tempos[path] = map;
      await BpmStore.save(path, map);
    } catch (e) {
      error = 'Analysis of ${baseName(path)} failed: $e';
    } finally {
      analyzing.remove(path);
      notifyListeners();
    }
  }

  // ---- transport options ----

  String? get current => index >= 0 && index < queue.length ? queue[index] : null;
  String? get next {
    final n = QueueService.nextIndex(index, queue.length, repeat: repeat);
    return n == null ? null : queue[n];
  }

  void toggleRepeat() {
    repeat = !repeat;
    _prefs?.setBool('repeat', repeat);
    if (index >= 0) unawaited(_setNext(next));
    notifyListeners();
  }

  /// Transition between songs: false = gapless, true = crossfade by [fadeSec].
  bool get crossfade => player.crossfade;
  double get fadeSec => player.fadeSec;
  void setCrossfade({bool? enabled, double? seconds}) {
    if (enabled != null) {
      player.crossfade = enabled;
      _prefs?.setBool('xfade', enabled);
    }
    if (seconds != null) {
      player.fadeSec = seconds;
      _prefs?.setDouble('xfadeSec', seconds);
    }
    notifyListeners();
  }

  void setMode(PlayMode m) {
    mode = m;
    _prefs?.setInt('mode', m.index);
    notifyListeners();
  }

  void setSkipSilence(bool v) {
    skipSilence = v;
    _prefs?.setBool('skipSilence', v);
    notifyListeners();
  }

  // ---- keep screen on ----

  /// Whether the screen stays on while Now Playing is open and audio plays.
  bool keepScreenOn = true;
  void setKeepScreenOn(bool v) {
    keepScreenOn = v;
    _prefs?.setBool('keepScreenOn', v);
    _syncKeepScreenOn();
    notifyListeners();
  }

  /// Whether [applyKeepScreenOn] does anything (shows the setting).
  bool get supportsKeepScreenOn => false;

  /// Keeps the screen on or lets it sleep; called only when that changes.
  @protected
  void applyKeepScreenOn(bool on) {}

  late final KeepScreenOnGate _keepScreen = KeepScreenOnGate(applyKeepScreenOn);

  bool get nowPlayingVisible => _keepScreen.visible;

  /// Called by Now Playing views as they appear and go away.
  void nowPlayingShown() {
    _keepScreen.shown();
    _syncKeepScreenOn();
  }

  void nowPlayingHidden() {
    _keepScreen.hidden();
    _syncKeepScreenOn();
  }

  void _syncKeepScreenOn() => _keepScreen.update(
      supported: supportsKeepScreenOn,
      enabled: keepScreenOn,
      playing: _playbackReady && player.playing);

  void setLyricsSource(String id, bool on) {
    on ? enricher.disabledSources.remove(id) : enricher.disabledSources.add(id);
    _prefs?.setStringList('lyricsOff', enricher.disabledSources.toList());
    notifyListeners();
  }

  void setGeniusToken(String token) {
    enricher.geniusToken = token.trim().isEmpty ? null : token.trim();
    _prefs?.setString('geniusToken', token.trim());
    notifyListeners();
  }

  // ---- spectrum ----

  String? _spectrumPath;
  Future<SpectrumAnalyzer?>? _spectrumFuture;

  /// Decodes [path] once (background isolate) and caches it for the current track only.
  Future<SpectrumAnalyzer?> spectrumFor(String path) {
    if (_spectrumPath == path && _spectrumFuture != null) return _spectrumFuture!;
    _spectrumPath = path;
    return _spectrumFuture = () async {
      try {
        final d = await decodeFileInIsolate(path);
        return SpectrumAnalyzer(d.mono, d.sampleRate);
      } catch (_) {
        return null;
      }
    }();
  }

  /// Now Playing sections the user has hidden.
  bool showView(String id) => !hiddenViews.contains(id);
  void toggleView(String id) {
    hiddenViews.contains(id) ? hiddenViews.remove(id) : hiddenViews.add(id);
    _prefs?.setStringList('npHidden', hiddenViews.toList());
    if (id == 'click') unawaited(_syncClicker());
    notifyListeners();
  }

  // ---- waveform & metronome ----

  String? _wavePath;
  Future<WaveformData?>? _waveFuture;
  WaveformData? wave;
  final Map<String, double> _beatOffsets = {};

  /// Waveform and onset envelope for [path], from its .wave file or computed once.
  Future<WaveformData?> waveformFor(String path) {
    if (_wavePath == path && _waveFuture != null) return _waveFuture!;
    _wavePath = path;
    wave = null;
    _beatOffsets.clear();
    return _waveFuture = () async {
      try {
        var w = await WaveformStore.load(path);
        if (w == null) {
          w = await computeWaveformForFile(path);
          await WaveformStore.save(path, w);
        }
        if (_wavePath == path) {
          wave = w;
          notifyListeners();
        }
        return w;
      } catch (_) {
        return null;
      }
    }();
  }

  WaveformData? waveOf(String path) => _wavePath == path ? wave : null;

  /// 0 on a beat rising towards 1, or null if the song has no tempo map.
  double? beatPhaseAt(String path, double pos) {
    final seg = mapOf(path)?.segmentAt(pos);
    if (seg == null) return null;
    var offset = 0.0;
    final w = _wavePath == path ? wave : null;
    if (w != null) {
      offset = _beatOffsets.putIfAbsent('$algorithm|${seg.startSec}',
          () => beatOffset(w, seg.startSec, seg.endSec, seg.bpm));
    }
    return beatPhase(pos, seg.startSec, offset, seg.bpm);
  }

  AudioPlayer? _click;
  Timer? _clickTimer;
  double _lastPhase = 0;
  static const _clickLead = 0.04; // compensates output latency of the click player

  Future<void> _syncClicker() async {
    final want = showView('click') && player.playing;
    if (!want) {
      _clickTimer?.cancel();
      _clickTimer = null;
      return;
    }
    if (_clickTimer != null) return;
    if (_click == null) {
      final tmp = await getTemporaryDirectory();
      final f = File('${tmp.path}${Platform.pathSeparator}${appId}_click.wav');
      await f.writeAsBytes(clickWav());
      final p = AudioPlayer();
      await p.setFilePath(f.path);
      _click = p;
    }
    _clickTimer ??= Timer.periodic(const Duration(milliseconds: 20), (_) => _clickTick());
  }

  void _clickTick() {
    final path = current;
    if (path == null) return;
    final ph = beatPhaseAt(path, player.position.inMilliseconds / 1000 + _clickLead);
    if (ph == null) return;
    if (ph < _lastPhase - 0.5) {
      final c = _click!;
      unawaited(c.seek(Duration.zero).then((_) => c.play()));
    }
    _lastPhase = ph;
  }

  // ---- transition alerts ----

  /// Enabled [alertTypes] given as an activity change approaches and arrives.
  Set<String> alerts = {};
  void setAlert(String type, bool on) {
    on ? alerts.add(type) : alerts.remove(type);
    _prefs?.setStringList('alerts', alerts.toList());
    notifyListeners();
  }

  /// While set, the screen flashes for the change to [flashLabel].
  DateTime? flashUntil;
  String? flashLabel;
  Timer? _flashTimer;

  String? _alertPath, _alertMarksPath, _stepsPath, _nextSongStep;
  double? _alertPrev;
  List<AlertMark> _alertMarks = const [];
  AlertMark? _alertEnd;
  AudioPlayer? _beep, _goBeep;
  FlutterTts? _tts;

  void _alertTick(Duration d) {
    if (alerts.isEmpty) return;
    final path = current;
    if (path == null) return;
    if (path != _alertPath) {
      // The song ended into a new activity before its last position report.
      final end = _alertEnd, prev = _alertPrev;
      if (end != null && prev != null && prev < end.at && end.at - prev < 3) _fireAlerts([end]);
      _alertPath = path;
      _alertPrev = null;
      _alertMarksPath = null;
      _alertEnd = null;
    }
    if (_alertMarksPath != path && _stepsPath == path) {
      final plan = currentPlan;
      final dur = player.duration;
      final len = plan != null && plan.segments.isNotEmpty && plan.segments.last.end > 0
          ? plan.segments.last.end
          : dur == null ? null : dur.inMilliseconds / 1000 - player.clipStart;
      if (len == null && _nextSongStep != null) return; // wait for the duration
      _alertMarks = alertMarks(plan, songLength: len, nextLabel: _nextSongStep);
      _alertEnd = _nextSongStep == null || _alertMarks.isEmpty ? null : _alertMarks.last;
      _alertMarksPath = path;
    }
    final pos = d.inMilliseconds / 1000 - player.clipStart;
    final due = _alertMarksPath == path ? dueAlerts(_alertPrev, pos, _alertMarks) : const <AlertMark>[];
    _alertPrev = pos;
    if (due.isEmpty) return;
    if (due.contains(_alertEnd)) _alertEnd = null;
    _fireAlerts(due);
  }

  void _fireAlerts(List<AlertMark> due) {
    // Several at once (a short gap) collapse to the most important.
    final m = due.firstWhere((a) => a.kind == AlertKind.go,
        orElse: () => due.firstWhere((a) => a.kind == AlertKind.voice, orElse: () => due.first));
    switch (m.kind) {
      case AlertKind.voice:
        if (alerts.contains('voice')) _say(m.text!);
      case AlertKind.beep:
        if (alerts.contains('beep')) unawaited(_playBeep(go: false));
      case AlertKind.go:
        if (alerts.contains('beep')) unawaited(_playBeep(go: true));
        if (alerts.contains('voice') && !alerts.contains('beep')) _say(m.text!);
        if (alerts.contains('vibrate')) {
          unawaited(HapticFeedback.heavyImpact().catchError((_) {}));
          unawaited(HapticFeedback.vibrate().catchError((_) {}));
        }
        if (alerts.contains('flash')) {
          flashUntil = DateTime.now().add(const Duration(milliseconds: 1500));
          flashLabel = m.text;
          _flashTimer?.cancel();
          _flashTimer = Timer(const Duration(milliseconds: 1500), () {
            flashUntil = flashLabel = null;
            notifyListeners();
          });
          notifyListeners();
        }
    }
  }

  void _say(String text) {
    try {
      _tts ??= FlutterTts();
      unawaited(_tts!.speak(text).catchError((_) => null));
    } catch (_) {}
  }

  Future<void> _playBeep({required bool go}) async {
    try {
      var p = go ? _goBeep : _beep;
      if (p == null) {
        final tmp = await getTemporaryDirectory();
        final f = File('${tmp.path}${Platform.pathSeparator}${appId}_${go ? 'go' : 'beep'}.wav');
        await f.writeAsBytes(go
            ? clickWav(seconds: 0.45, hz: 1320, decay: 0.3)
            : clickWav(seconds: 0.15, hz: 880, decay: 0.2));
        p = AudioPlayer();
        await p.setFilePath(f.path);
        go ? _goBeep = p : _beep = p;
      }
      await p.seek(Duration.zero);
      await p.play();
    } catch (_) {}
  }

  // ---- art & lyrics ----

  /// Keys of art downloads in flight (`s:` + song path, or `a:` + artist key).
  final Set<String> artBusy = {};

  /// Whether [downloadAlbumArt] does anything (shows the tap-to-download hint).
  bool get supportsArtDownload => false;

  /// Downloads album art for the album of [samplePath]; true when art was saved.
  Future<bool> downloadAlbumArt(String samplePath) async => false;

  /// Loads art and lyrics already on disk or embedded; no network.
  Future<void> ensureMedia(String path, {bool reload = false}) async {
    if (!reload && (media.containsKey(path) || _loadingMedia.contains(path))) return;
    _loadingMedia.add(path);
    try {
      final tags = await readTags(path);
      var art = await EnrichService.localArt(path, album: tags.album);
      if (art == null && tags.picture != null) {
        final tmp = await getTemporaryDirectory();
        final dir = Directory('${tmp.path}${Platform.pathSeparator}${appId}_art');
        await dir.create(recursive: true);
        art = File(
            '${dir.path}${Platform.pathSeparator}${path.hashCode.toRadixString(16)}_${tags.picture!.length}.img');
        if (!await art.exists()) await art.writeAsBytes(tags.picture!);
      }
      final lyrics = await EnrichService.localLyrics(path, embedded: tags.lyrics);
      media[path] = TrackMedia(
          art: art, lyrics: lyrics, title: tags.title, artist: tags.artist, album: tags.album);
    } catch (_) {
      media[path] = const TrackMedia();
    } finally {
      _loadingMedia.remove(path);
      notifyListeners();
    }
  }

  /// Fetches missing art and lyrics for one song from the internet.
  Future<bool> fetchMedia(String path, {bool force = true}) async {
    if (fetching.contains(path)) return false;
    fetching.add(path);
    enrichNote = null;
    notifyListeners();
    var ok = false;
    try {
      final r = await enricher.enrich(path,
          durationSec: tempos[path]?.durationSec, force: force);
      ok = r.artSaved || r.lyricsSaved;
      enrichNote = r.notes.isEmpty ? null : '${baseName(path)}: ${r.notes.join(', ')}';
      await ensureMedia(path, reload: true);
    } catch (e) {
      enrichNote = 'Fetch failed: $e';
    } finally {
      fetching.remove(path);
      notifyListeners();
    }
    return ok;
  }

  // ---- rating ----

  /// Whether the app stores per-song ratings (shows stars on Now Playing).
  bool get supportsRating => false;

  /// Star rating 0–5 for [path] (0 = unrated); must be synchronous and cheap.
  int ratingOf(String path) => 0;

  /// Whether [path] is marked as a favourite.
  bool favOf(String path) => false;

  /// Updates the rating and/or favourite flag of [path]; null leaves a value unchanged.
  Future<void> setRatingFor(String path, {int? rating, bool? fav}) async {}

  // ---- queue ----

  /// Plays [path]; the queue follows [mode]: the mix, or the song list.
  Future<void> play(String path) async {
    onPlayStarting();
    final mix = mixPaths;
    final all = mode == PlayMode.mix && mix.isNotEmpty ? [...mix] : libraryPaths;
    queue = _queueService.buildFrom(mode, all, mixList: [...mix], startWith: path);
    index = queue.indexOf(path);
    await loadCurrent();
  }

  /// Plays [paths] in the given order (or shuffled), replacing the queue.
  Future<void> playSongs(List<String> paths, {bool shuffle = false}) async {
    if (paths.isEmpty) return;
    onPlayStarting();
    queue = [...paths];
    if (shuffle) queue.shuffle(random);
    index = 0;
    await loadCurrent();
  }

  /// Plays the mix from its first song in mix order.
  Future<void> playMix() async {
    final mix = mixPaths;
    if (mix.isEmpty) return;
    setMode(PlayMode.mix);
    await play(mix.first);
  }

  /// Jumps to queue song [i] at [seconds] in; the same song just seeks.
  /// Plays song [i] from [seconds] after its (trimmed) start, the time base
  /// of its plan.
  Future<void> jumpTo(int i, {double seconds = 0}) async {
    if (i < 0 || i >= queue.length) return;
    if (i != index) {
      index = i;
      await loadCurrent();
    }
    try {
      await player.seek(Duration(milliseconds: ((seconds + player.clipStart) * 1000).round()));
    } catch (_) {}
  }

  Future<void> playNext() async {
    final n = QueueService.nextIndex(index, queue.length, repeat: repeat);
    if (n != null) {
      index = n;
      await loadCurrent();
    }
  }

  Future<void> playPrevious() async {
    if (player.position.inMilliseconds / 1000 - player.clipStart > 3 || index <= 0) {
      await player.seek(Duration.zero);
    } else {
      index--;
      await loadCurrent();
    }
  }

  /// Jumps past leading silence once the waveform is known.
  Future<void> _skipLeadingSilence(String path) async {
    if (!skipSilence) return;
    final w = await waveformFor(path);
    if (w == null || current != path || !skipSilence) return;
    final lead = leadingSilence(w);
    if (lead < 1.5) return;
    final target = Duration(milliseconds: ((lead - 0.3) * 1000).round());
    if (player.position < target) {
      try {
        await player.seek(target);
      } catch (_) {} // song or player went away while the waveform loaded
    }
  }

  /// The engine already started the pre-loaded next song on its own.
  void _onAdvanced() {
    final n = QueueService.nextIndex(index, queue.length, repeat: repeat);
    if (n == null) return;
    _finishPlay(completed: true);
    index = n;
    _syncStop();
    final path = current;
    if (path == null) return;
    _listening = path;
    error = null;
    unawaited(_skipLeadingSilence(path));
    unawaited(waveformFor(path));
    unawaited(_prepareAround(path));
    notifyListeners();
  }

  /// Track whose listening time is being measured for the play history.
  String? _listening;

  StopMode _stopMode = StopMode.none;
  DateTime? _stopAt;
  Timer? _stopTimer;
  StopMode get stopMode => _stopMode;

  /// When a timed stop will have silenced playback; null for other modes.
  DateTime? get stopAt => _stopAt;

  /// Arms the sleep timer. [minutes] is only used by [StopMode.minutes].
  void setStopTimer(StopMode mode, {int minutes = 0}) {
    _clearStop();
    _stopMode = mode;
    switch (mode) {
      case StopMode.none:
        break;
      case StopMode.minutes:
        final total = Duration(minutes: minutes);
        _stopAt = DateTime.now().add(total);
        final lead = total - const Duration(seconds: 8);
        _stopTimer = Timer(lead.isNegative ? Duration.zero : lead,
            () => player.fadeOutAndPause(
                  min(8, total.inMilliseconds / 1000).toDouble(),
                ));
      case StopMode.endOfSong:
        player.stopAtSongEnd = true;
      case StopMode.endOfMix:
        _syncStop();
    }
    notifyListeners();
  }

  void cancelStopTimer() => setStopTimer(StopMode.none);

  void _clearStop() {
    _stopTimer?.cancel();
    _stopTimer = null;
    _stopAt = null;
    _stopMode = StopMode.none;
    player.stopAtSongEnd = false;
  }

  void _onStopped() {
    _clearStop();
    notifyListeners();
  }

  /// End-of-mix stops on the final queue song, even when repeat is on.
  void _syncStop() {
    if (_stopMode == StopMode.endOfMix) {
      player.stopAtSongEnd = queue.isNotEmpty && index == queue.length - 1;
    }
  }

  void _finishPlay({required bool completed}) {
    final p = _listening;
    if (p == null) return;
    _listening = null;
    final secs = completed ? 9999.0 : player.position.inMilliseconds / 1000;
    onPlayFinished(p, secs, completed);
  }

  Future<void> _prepareAround(String path) async {
    await tempoFor(path);
    final n = next;
    if (n != null) await tempoFor(n);
    unawaited(ensureMedia(path));
    if (n != null) unawaited(ensureMedia(n));
    unawaited(_updateProgramSteps());
    notifyListeners();
    unawaited(_setNext(n));
  }

  /// Loudness levelling: plays loud songs quieter so every song sounds about
  /// as loud as the quieter ones (needs loudness measured on the PC).
  bool levelLoudness = true;

  void setLevelLoudness(bool v) {
    levelLoudness = v;
    _prefs?.setBool('levelLoudness', v);
    _trackCache.clear();
    if (index >= 0) unawaited(_setNext(next));
    notifyListeners();
  }

  final Map<String, ({double? start, double? end, double? loudness})> _trackCache = {};

  /// Trim points and loudness of [path]; by default from the mixtape's song
  /// metadata. analyze-this overrides this to read its library.
  Future<({double? start, double? end, double? loudness})> trackInfo(String path) async {
    double? n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    try {
      final m = await SongMeta.load(path);
      return (start: n(m?['start']), end: n(m?['end']), loudness: n(m?['loudness']));
    } catch (_) {
      return (start: null, end: null, loudness: null);
    }
  }

  /// What the engine should play for [path]: its clip and loudness gain.
  Future<EngineTrack> engineTrack(String path) async {
    final t = _trackCache[path] ??= await trackInfo(path);
    final start = t.start != null && t.start! > 0 ? t.start : null;
    final end = t.end != null && (start == null || t.end! > start) ? t.end : null;
    return EngineTrack(path,
        start: start, end: end, gain: levelLoudness ? gainForLoudness(t.loudness) : 1);
  }

  Future<void> _setNext(String? path) async =>
      player.setNext(path == null ? null : await engineTrack(path));

  /// Forgets cached trim/loudness (after they were edited).
  void clearTrackCache([String? path]) => path == null ? _trackCache.clear() : _trackCache.remove(path);

  /// The instructor's coaching cue for [path] in this mix; by default the
  /// one imported with the mixtape. analyze-this reads its mix instead.
  Future<String?> noteOf(String path) async {
    try {
      final n = (await SongMeta.load(path))?['note'];
      return n is String && n.trim().isNotEmpty ? n.trim() : null;
    } catch (_) {
      return null;
    }
  }

  /// Coaching cue of the song now playing.
  String? currentNote;

  /// Program/class part name for [path] (from the mixtape's song metadata),
  /// cached since it is looked up for several songs ahead in the queue.
  Future<String?> stepOf(String path) async {
    if (_stepCache.containsKey(path)) return _stepCache[path];
    String? step;
    try {
      step = (await SongMeta.load(path))?['step'] as String?;
    } catch (_) {}
    return _stepCache[path] = step;
  }

  /// Timed plan for [path]; by default the one imported with the mixtape.
  /// analyze-this overrides this to build plans straight from its mix.
  Future<StepPlan?> planOf(String path) async {
    if (_planCache.containsKey(path)) return _planCache[path];
    StepPlan? plan;
    try {
      final j = (await SongMeta.load(path))?['plan'];
      if (j is Map) plan = StepPlan.fromJson(j.cast<String, dynamic>());
    } catch (_) {}
    return _planCache[path] = plan;
  }

  /// Trainer notes of the song now playing, shown at their timestamps.
  List<TimedNote> currentTimedNotes = const [];

  /// Notes of [path]; hosts with their own store override this (the phone
  /// reads them from the song's plan).
  Future<List<TimedNote>> timedNotesOf(String path) async => (await planOf(path))?.timedNotes ?? const [];

  /// Set by a host that can store notes: adds [text] at [atSec] of [path].
  /// Null hides the "Add note" buttons.
  bool Function(String path, double atSec, String text)? addTimedNote;

  /// Re-reads the plans and notes of the song now playing (after an edit).
  Future<void> refreshPlans() {
    _planCache.clear();
    return _updateProgramSteps();
  }

  /// Refreshes the step/plan fields for the song now playing: the next
  /// step is the nearest upcoming song whose part differs from the current one.
  Future<void> _updateProgramSteps() async {
    final path = current;
    if (path == null) {
      currentStep = nextStep = null;
      currentTimedNotes = const [];
      currentPlan = nextSongPlan = nextPlan = prevPlan = null;
      upcomingSteps = const [];
      mixBlocks = const [];
      notifyListeners();
      return;
    }
    final curPlan = await planOf(path);
    final prevSongPlan = index > 0 && index - 1 < queue.length ? await planOf(queue[index - 1]) : null;
    final cur = curPlan?.activity ?? await stepOf(path);
    String? nxt;
    StepPlan? nxtPlan, nxtSong;
    String? nextSongStep;
    final ahead = <UpcomingStep>[];
    final blocks = <MixBlock>[];
    var songStart = 0.0, clock = 0.0;
    if (cur != null) {
      var last = cur;
      for (var i = index + 1; i < queue.length; i++) {
        final plan = await planOf(queue[i]);
        final s = plan?.activity ?? await stepOf(queue[i]);
        if (i == index + 1) {
          nxtSong = plan;
          nextSongStep = s != null && s != cur ? s : null;
        }
        if (s == null || s == last) continue;
        if (nxt == null) {
          nxt = s;
          nxtPlan = plan;
        }
        ahead.add(UpcomingStep(s, plan, i));
        if (ahead.length >= 3) break;
        last = s;
      }
      if (queue.length <= 200) {
        var name = cur;
        for (var i = 0; i < queue.length; i++) {
          final plan = i == index ? curPlan : await planOf(queue[i]);
          final s = plan?.activity ?? await stepOf(queue[i]) ?? name;
          final secs = (plan != null && plan.segments.isNotEmpty ? plan.segments.last.end : 0) > 0
              ? plan!.segments.last.end
              : tempos[queue[i]]?.durationSec ?? 240.0;
          if (i == index) songStart = clock;
          if (blocks.isNotEmpty && blocks.last.activity == s) {
            final b = blocks.removeLast();
            blocks.add(MixBlock(s, b.plan, b.start, b.seconds + secs, b.firstSong, b.songs + 1));
          } else {
            blocks.add(MixBlock(s, plan, clock, secs, i, 1));
          }
          name = s;
          clock += secs;
        }
      }
    }
    final note = await noteOf(path);
    final timed = await timedNotesOf(path);
    if (current != path) return; // superseded by a later track change
    currentNote = note;
    currentTimedNotes = timed;
    _stepsPath = path;
    _nextSongStep = nextSongStep;
    _alertMarksPath = null;
    mixBlocks = blocks;
    mixSongStart = songStart;
    mixTotalSeconds = clock;
    upcomingSteps = ahead;
    currentStep = cur;
    nextStep = nxt;
    currentPlan = curPlan;
    nextSongPlan = nxtSong;
    prevPlan = prevSongPlan;
    nextPlan = nxtPlan;
    notifyListeners();
  }

  /// Loads the song at [index]. [preview] auditions are not counted as plays.
  @protected
  Future<void> loadCurrent({bool preview = false}) async {
    final path = current;
    if (path == null) return;
    if (!preview) _finishPlay(completed: false);
    try {
      error = null;
      await tempoFor(path);
      final n = next;
      if (n != null) await tempoFor(n);
      unawaited(waveformFor(path));
      unawaited(ensureMedia(path));
      if (n != null) unawaited(ensureMedia(n));
      unawaited(_updateProgramSteps());
      notifyListeners();
      await player.load(await engineTrack(path));
      _syncStop();
      if (!preview) {
        _listening = path;
        unawaited(_skipLeadingSilence(path));
      }
      unawaited(_setNext(n));
    } catch (e) {
      error = 'Cannot play ${baseName(path)}: $e';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _stopTimer?.cancel();
    _keepScreen.close();
    _clickTimer?.cancel();
    _click?.dispose();
    if (_playbackReady || index >= 0) player.dispose();
    super.dispose();
  }
}
