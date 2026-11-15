import 'package:shared_core/services/m3u.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseM3u keeps order, skips comments/streams, resolves relative', () {
    final paths = parseM3u(
        '\uFEFF#EXTM3U\r\n#EXTINF:200,X - A\r\nC:\\m\\a.mp3\r\n\r\nrel\\b.mp3\r\n'
        'http://example.com/s.mp3\r\nfile:///C:/m/c%20d.mp3\r\n',
        baseDir: 'C:\\base');
    expect(paths, ['C:\\m\\a.mp3', 'C:\\base\\rel\\b.mp3', 'C:\\m\\c d.mp3']);
  });

  test('buildM3u8 writes the program header and relative paths inside baseDir', () {
    final text = buildM3u8([
      const MixEntry('C:\\mix\\songs\\a.mp3', 'A', artist: 'X', durationSec: 60.4),
      const MixEntry('C:\\other\\b.mp3', 'B'),
    ], program: 'Classic\nProgram', baseDir: 'C:\\mix');
    expect(text,
        '#EXTM3U\n#EXT-X-PROGRAM:Classic Program\n#EXTINF:60,X - A\nsongs/a.mp3\n#EXTINF:-1,B\nC:\\other\\b.mp3\n');
    expect(buildM3u8([const MixEntry('C:\\m\\a.mp3', 'A')]), '#EXTM3U\n#EXTINF:-1,A\nC:\\m\\a.mp3\n');
  });
}
