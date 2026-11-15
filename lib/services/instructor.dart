import '../models/step_plan.dart';

/// One piece of instructor advice and the icon key (see `iconForKey`) to show with it.
class Advice {
  const Advice(this.text, this.icon);
  final String text;
  final String icon;
}

/// What to do right now and what comes next.
class InstructorTips {
  const InstructorTips(this.now, this.next);
  final Advice? now;
  final Advice? next;
}

const warmupStretches = [
  'Neck rolls: slow circles, five each way',
  'Shoulder rolls: ten backward, ten forward',
  'Cross-body shoulder stretch: hold, then switch arms',
  'Overhead triceps stretch: reach down your back',
  'Chest opener: hands behind you, lift and open',
  'Wrists and forearms: gentle circles and flexes',
  'Seated cat-cow: round and arch the upper back',
];

const cooldownStretches = [
  'Quad stretch: heel to glute, hold each leg',
  'Hamstring stretch: heel on the saddle, fold forward',
  'Hip flexor lunge: sink the hips, hold each side',
  'Glute stretch: ankle across the knee, sit back',
  'Calf stretch: heel down, lean into the wall',
  'Chest and shoulders: clasp hands behind, open up',
  'Forward fold: let the back and neck release',
];

const _resetSeconds = 15.0;
const _warmupPeriod = 30.0;
const _stretchPeriod = 40.0;
const _sprintIcons = {'sprint', 'tabata', 'surge'};

class _Window {
  const _Window(this.start, this.end, this.advice);
  final double start, end;
  final Advice advice;
}

String _secs(double s) => '${s.round()} s';

double _planEnd(StepPlan plan) => plan.segments.isEmpty ? 600 : plan.segments.last.end;

List<_Window> _series(double from, double end, double period, List<String> items, String icon) => [
      for (var t = from, i = 0; t < end - 1; t += period, i++)
        _Window(t, t + period > end - 1 ? end : t + period, Advice(items[i % items.length], icon)),
    ];

/// Advice windows for one song's plan, in time order.
List<_Window> _timeline(StepPlan plan, StepPlan? prev, {required bool last}) {
  final end = _planEnd(plan);
  final startsActivity = prev == null || prev.activity != plan.activity || plan.icon == 'hill';
  final afterHill = prev?.icon == 'hill' && _sprintIcons.contains(plan.icon);
  final reset = afterHill
      ? Advice('Reset to base resistance and hit ${plan.maxRpm.round()} RPM', 'sprint')
      : const Advice('Reset to your base resistance', 'steady');

  switch (plan.icon) {
    case 'warmup':
      final from = startsActivity ? _resetSeconds : 0.0;
      return [
        if (startsActivity) _Window(0, from, reset),
        ..._series(from, end, _warmupPeriod, warmupStretches, 'warmup'),
      ];
    case 'stretch':
      return _series(0, end, _stretchPeriod, cooldownStretches, 'stretch');
    case 'cooldown':
      if (last) return _series(0, end, _stretchPeriod, cooldownStretches, 'stretch');
      return [
        if (startsActivity) _Window(0, _resetSeconds, reset),
        _Window(startsActivity ? _resetSeconds : 0, end,
            const Advice('Drop to a light gear and breathe deeply', 'cooldown')),
      ];
  }

  final segs = plan.segments;
  if (segs.isEmpty) return [if (startsActivity) _Window(0, end, reset)];

  final out = <_Window>[];
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    Advice? a;
    switch (s.icon) {
      case 'work':
        final rest = i + 1 < segs.length && segs[i + 1].icon == 'rest' ? segs[i + 1] : null;
        a = Advice(
            '${_round(s)}all out for ${_secs(s.length)}${rest == null ? '' : ', then rest ${_secs(rest.length)}'}',
            'work');
      case 'rest':
        final work = i + 1 < segs.length && segs[i + 1].icon == 'work' ? segs[i + 1] : null;
        a = Advice(
            '${_round(s)}rest for ${_secs(s.length)}${work == null ? '' : ', then ${_secs(work.length)} all out'}',
            'rest');
      case 'resistance':
      case 'summit':
        a = Advice(
            s.icon == 'summit'
                ? 'Add 2 to your base resistance: heaviest step, hold it to the top'
                : 'Add 2 to your base resistance',
            s.icon);
      case 'spin':
        a = Advice('Drop the resistance and spin up', 'spin');
      default:
        if (i == 0 && startsActivity) {
          a = reset;
        } else if (s.cue != null || segs.length == 1) {
          a = segs.length == 1 && s.cue == null
              ? null
              : Advice(segs.length == 1 ? s.cue! : '${s.label}: ${s.cue}', s.icon);
        }
    }
    if (a != null) out.add(_Window(s.start, s.end, a));
  }
  return out;
}

String _round(StepSegment s) {
  final c = s.cue;
  if (c != null && c.startsWith('Round')) return '${c.split(' · ').first}: ';
  return '';
}

/// Advice for the song at [pos] seconds into [cur], and for what follows.
/// [prev] and [nextSong] are the neighbouring songs' plans (null at the ends
/// of the mix or without a plan). A cool-down with no [nextSong] is the last
/// activity, so it gets off-the-bike stretches.
InstructorTips instructorAdvice({
  StepPlan? prev,
  required StepPlan cur,
  StepPlan? nextSong,
  required double pos,
}) {
  final wins = _timeline(cur, prev, last: nextSong == null);
  var i = wins.indexWhere((w) => pos < w.end);
  if (i < 0 && wins.isNotEmpty) i = wins.length - 1;
  final now = i < 0 ? null : wins[i].advice;

  Advice? next;
  if (i >= 0) {
    for (var j = i + 1; j < wins.length; j++) {
      if (wins[j].advice.text != now?.text) {
        next = wins[j].advice;
        break;
      }
    }
  }
  if (next == null && nextSong != null) {
    final n = _timeline(nextSong, cur, last: false);
    if (n.isNotEmpty) next = n.first.advice;
  }
  return InstructorTips(now, next);
}
