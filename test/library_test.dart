import 'dart:io';

import 'package:shared_core/models/tempo.dart';
import 'package:shared_core/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scan recurses into subfolders', () async {
    final d = Directory.systemTemp.createTempSync('scan');
    Directory('${d.path}/a/b').createSync(recursive: true);
    File('${d.path}/x.mp3').writeAsStringSync('');
    File('${d.path}/a/y.MP3').writeAsStringSync('');
    File('${d.path}/a/b/z.mp3').writeAsStringSync('');
    File('${d.path}/a/skip.txt').writeAsStringSync('');
    final r = await scanMp3s(d.path);
    expect(r.length, 3);
    expect(relativeName(r.last, d.path).replaceAll('\\', '/'), 'x.mp3');
    d.deleteSync(recursive: true);
  });

  test('median is duration weighted', () {
    final m = TempoMap(durationSec: 100, segments: const [
      TempoSegment(0, 10, 90),
      TempoSegment(10, 20, 100),
      TempoSegment(20, 100, 140),
    ]);
    expect(m.medianBpm, 140);
    expect(m.averageBpm, closeTo(131, 0.1));
  });
}
