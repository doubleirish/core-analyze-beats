import 'dart:math';

import 'package:shared_core/services/queue_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final all = ['/m/c.mp3', '/m/A.mp3', '/m/b.mp3'];
  final q = QueueService(random: Random(1));

  test('alphabetical is case-insensitive', () {
    expect(q.build(PlayMode.alphabetical, all), ['/m/A.mp3', '/m/b.mp3', '/m/c.mp3']);
  });

  test('shuffle keeps all and starts with chosen track', () {
    final r = q.build(PlayMode.shuffle, all, startWith: '/m/c.mp3');
    expect(r.first, '/m/c.mp3');
    expect(r.toSet(), all.toSet());
  });

  test('mix keeps user order and drops missing files', () {
    expect(q.build(PlayMode.mix, all, mixList: ['/m/c.mp3', '/gone.mp3', '/m/A.mp3']),
        ['/m/c.mp3', '/m/A.mp3']);
  });

  test('single-song start keeps playing: mix fallbacks', () {
    expect(q.buildFrom(PlayMode.mix, all, mixList: [], startWith: '/m/b.mp3'),
        ['/m/b.mp3', '/m/c.mp3', '/m/A.mp3']);
    expect(q.buildFrom(PlayMode.mix, all, mixList: ['/m/c.mp3', '/m/A.mp3'], startWith: '/m/b.mp3'),
        ['/m/b.mp3', '/m/c.mp3', '/m/A.mp3']);
    expect(q.buildFrom(PlayMode.alphabetical, all, startWith: '/m/b.mp3'),
        ['/m/A.mp3', '/m/b.mp3', '/m/c.mp3']);
  });

  test('nextIndex wraps only with repeat', () {
    expect(QueueService.nextIndex(0, 3, repeat: false), 1);
    expect(QueueService.nextIndex(2, 3, repeat: false), isNull);
    expect(QueueService.nextIndex(2, 3, repeat: true), 0);
    expect(QueueService.nextIndex(0, 1, repeat: true), 0);
    expect(QueueService.nextIndex(-1, 3, repeat: true), isNull);
  });
}
