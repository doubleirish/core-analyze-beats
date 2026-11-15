import 'dart:math';

enum PlayMode { alphabetical, shuffle, mix }

/// Produces the play order for a set of tracks.
class QueueService {
  QueueService({Random? random}) : _random = random ?? Random();
  final Random _random;

  List<String> build(PlayMode mode, List<String> all,
      {List<String> mixList = const [], String? startWith}) {
    final sorted = [...all]
      ..sort((a, b) => _name(a).toLowerCase().compareTo(_name(b).toLowerCase()));
    List<String> order;
    switch (mode) {
      case PlayMode.alphabetical:
        order = sorted;
      case PlayMode.shuffle:
        order = [...sorted]..shuffle(_random);
        if (startWith != null && order.remove(startWith)) {
          order.insert(0, startWith);
        }
      case PlayMode.mix:
        final set = all.toSet();
        order = mixList.where(set.contains).toList();
    }
    return order;
  }

  /// Order to play when [startWith] was picked: follows [mode], but never ends
  /// after one song just because the mix list is empty or lacks it.
  List<String> buildFrom(PlayMode mode, List<String> all,
      {List<String> mixList = const [], required String startWith}) {
    var q = build(mode, all, mixList: mixList, startWith: startWith);
    if (!q.contains(startWith)) q = [startWith, ...q];
    if (q.length == 1 && all.length > 1) {
      q = build(PlayMode.alphabetical, all);
      if (!q.contains(startWith)) q = [startWith, ...q];
      final i = q.indexOf(startWith);
      q = [...q.sublist(i), ...q.sublist(0, i)];
    }
    return q;
  }

  /// Index of the song after [i], wrapping to the start when [repeat]; null at the end.
  static int? nextIndex(int i, int length, {required bool repeat}) {
    if (i < 0 || length == 0) return null;
    if (i + 1 < length) return i + 1;
    return repeat ? 0 : null;
  }

  static String _name(String p) => p.split(RegExp(r'[\\/]')).last;
}
