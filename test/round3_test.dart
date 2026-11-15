import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/models/step_plan.dart';
import 'package:shared_core/services/loudness.dart';
import 'package:shared_core/services/mixtape/manifest.dart';
import 'package:shared_core/services/transition_alerts.dart';

Float64List sine(double amp, {int sr = 48000, double secs = 3, double hz = 997}) =>
    Float64List.fromList([for (var i = 0; i < sr * secs; i++) amp * math.sin(2 * math.pi * hz * i / sr)]);

void main() {
  group('loudness', () {
    test('a full-scale 997 Hz sine reads about -3 LUFS at any rate', () {
      expect(integratedLoudness(sine(1), 48000), closeTo(-3.01, 0.1));
      expect(integratedLoudness(sine(1, sr: 44100), 44100), closeTo(-3.01, 0.1));
    });

    test('halving the level lowers it by 6 LU; silence and short input are null', () {
      final full = integratedLoudness(sine(1), 48000)!;
      expect(integratedLoudness(sine(0.5), 48000), closeTo(full - 6.02, 0.05));
      expect(integratedLoudness(Float64List(48000), 48000), isNull);
      expect(integratedLoudness(sine(1, secs: 0.2), 48000), isNull);
    });

    test('gain turns loud songs down, never boosts, and respects the floor', () {
      expect(gainForLoudness(-8), closeTo(math.pow(10, -6 / 20), 1e-9));
      expect(gainForLoudness(-20), 1);
      expect(gainForLoudness(null), 1);
      expect(gainForLoudness(10), 0.25);
      expect(targetForMix([-8, -9, -10, -11, -12]), -14);
      expect(targetForMix([-16, -17, -18, -19, -20]), -19);
      expect(targetForMix([null]), isNull);
    });
  });

  group('manifest trim, loudness and notes', () {
    MixtapeTrack track({double? start, double? end, double? loudness, String? note}) => MixtapeTrack(
        file: 'songs/a.mp3', sha256: 'x', size: 10, duration: 200,
        start: start, end: end, loudness: loudness, note: note);

    MixtapeManifest manifest(MixtapeTrack t) => MixtapeManifest(
        id: 'mix1', name: 'Ride', transport: Transport.all.first, createdAt: 0, source: 'test', tracks: [t]);

    test('round-trips and the playlist uses the trimmed length', () {
      final m = MixtapeManifest.decode(manifest(track(start: 10, end: 130, loudness: -9.5, note: 'Climb')).encode());
      final t = m.tracks.single;
      expect([t.start, t.end, t.loudness, t.note], [10, 130, -9.5, 'Climb']);
      expect(t.playSeconds, 120);
      expect(relativePlaylist(m.tracks), contains('#EXTINF:120,'));
    });

    test('rejects bad trims and loudness', () {
      for (final t in [track(start: 50, end: 40), track(start: -1), track(end: double.nan), track(loudness: 50)]) {
        expect(() => manifest(t).validate(), throwsFormatException);
      }
    });

    test('step plans carry the part notes', () {
      const plan = StepPlan(activity: 'Climb', icon: 'climb', minRpm: 60, maxRpm: 80, notes: 'Stay seated');
      expect(StepPlan.fromJson(plan.toJson()).notes, 'Stay seated');
    });
  });

  group('transition alerts', () {
    StepSegment seg(String l, double a, double b, {bool lead = false}) =>
        StepSegment(label: l, start: a, end: b, minRpm: 80, maxRpm: 90, lead: lead);
    final plan = StepPlan(activity: 'Climb', icon: '', minRpm: 60, maxRpm: 70, segments: [
      seg('Warm', 0, 20, lead: true),
      seg('Seated', 20, 60),
      seg('Seated', 60, 100),
      seg('Standing', 100, 170),
      seg('Out', 170, 180, lead: true),
    ]);

    test('marks each activity change and a different next song, not repeats or leads', () {
      final m = alertMarks(plan, songLength: 180, nextLabel: 'Sprint');
      final go = m.where((a) => a.kind == AlertKind.go).toList();
      expect(go.map((a) => (a.at, a.text)), [(20.0, 'Seated'), (100.0, 'Standing'), (179.75, 'Sprint')]);
      expect(m.where((a) => a.kind == AlertKind.voice).map((a) => a.at), [10.0, 90.0, 169.75]);
      expect(m.where((a) => a.kind == AlertKind.beep).length, 9);
      expect(alertMarks(plan, songLength: 180).where((a) => a.kind == AlertKind.go).length, 2);
      expect(alertMarks(null, songLength: 200), isEmpty);
    });

    test('only normal playback fires; seeks and track starts do not', () {
      final m = alertMarks(plan, songLength: 180, nextLabel: 'Sprint');
      expect(dueAlerts(96.8, 97.1, m).single.kind, AlertKind.beep);
      expect(dueAlerts(99.9, 100.1, m).single.text, 'Standing');
      expect(dueAlerts(null, 100.1, m), isEmpty);
      expect(dueAlerts(50, 100.1, m), isEmpty, reason: 'seek forward');
      expect(dueAlerts(101, 99.5, m), isEmpty, reason: 'seek back');
      expect(dueAlerts(179.6, 179.8, m).single.kind, AlertKind.go);
    });
  });
}
