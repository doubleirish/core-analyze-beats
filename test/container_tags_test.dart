import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_core/services/library_service.dart';
import 'package:shared_core/services/tags.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List box(String type, List<int> body) {
  final b = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, body.length + 8)).buffer.asUint8List())
    ..add(latin1.encode(type))
    ..add(body);
  return b.toBytes();
}

List<int> item(String name, List<int> payload) =>
    box(name, box('data', [0, 0, 0, 1, 0, 0, 0, 0, ...payload]));

Uint8List fakeM4a() {
  final ilst = box('ilst', [
    ...item('\u00a9nam', utf8.encode('One')),
    ...item('\u00a9ART', utf8.encode('U2')),
    ...item('\u00a9alb', utf8.encode('Achtung Baby')),
    ...item('\u00a9day', utf8.encode('1991-11-18')),
    ...item('\u00a9gen', utf8.encode('Rock')),
    ...item('covr', [0xff, 0xd8, 1, 2, 3]),
  ]);
  final moov = box('moov', box('udta', box('meta', [0, 0, 0, 0, ...ilst])));
  return Uint8List.fromList([
    ...box('ftyp', latin1.encode('M4A \x00\x00\x00\x00')),
    ...box('mdat', List.filled(1000, 7)),
    ...moov,
  ]);
}

List<int> u16(String s) => [for (final u in s.codeUnits) ...[u & 255, u >> 8], 0, 0];

Uint8List fakeWma() {
  List<int> le(int v, int n) => [for (var i = 0; i < n; i++) (v >> (8 * i)) & 255];
  List<int> hex(String h) =>
      [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
  List<int> obj(String guid, List<int> body) => [...hex(guid), ...le(body.length + 24, 8), ...body];

  final t = u16('Sunday Bloody Sunday'), a = u16('U2');
  final content = obj('3326b2758e66cf11a6d900aa0062ce6c', [
    ...le(t.length, 2), ...le(a.length, 2), ...le(0, 2), ...le(0, 2), ...le(0, 2), ...t, ...a,
  ]);
  List<int> attr(String name, int type, List<int> v) =>
      [...le(u16(name).length, 2), ...u16(name), ...le(type, 2), ...le(v.length, 2), ...v];
  final pic = [3, ...le(3, 4), ...u16('image/jpeg'), ...u16(''), 9, 8, 7];
  final ext = obj('40a4d0d207e3d21197f000a0c95ea850', [
    ...le(4, 2),
    ...attr('WM/AlbumTitle', 0, u16('War')),
    ...attr('WM/Year', 0, u16('1983')),
    ...attr('WM/Genre', 0, u16('Rock')),
    ...attr('WM/Picture', 1, pic),
  ]);
  final objects = [...content, ...ext];
  return Uint8List.fromList([
    ...hex('3026b2758e66cf11a6d900aa0062ce6c'),
    ...le(objects.length + 30, 8),
    ...le(2, 4), 1, 2,
    ...objects,
    ...List.filled(50, 0),
  ]);
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('container_tags_'));
  tearDown(() => tmp.delete(recursive: true));

  Future<String> write(String name, List<int> bytes) async {
    final f = File('${tmp.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('reads m4a (iTunes atoms) tags, year and cover', () async {
    final t = await readTags(await write('x.m4a', fakeM4a()));
    expect((t.title, t.artist, t.album, t.genre, t.year), ('One', 'U2', 'Achtung Baby', 'Rock', 1991));
    expect(t.picture, [0xff, 0xd8, 1, 2, 3]);
  });

  test('reads wma (ASF) tags and cover', () async {
    final t = await readTags(await write('x.wma', fakeWma()));
    expect((t.title, t.artist, t.album, t.genre, t.year),
        ('Sunday Bloody Sunday', 'U2', 'War', 'Rock', 1983));
    expect(t.picture, [9, 8, 7]);
  });

  test('untagged or corrupt files fall back to the filename', () async {
    final t = await readTags(await write('U2 - Bad.m4a', [1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect((t.artist, t.title), ('U2', 'Bad'));
    expect((await readTags(await write('Zero.wma', List.filled(40, 0)))).title, 'Zero');
  });

  test('folder scan includes mp3, m4a and wma only', () async {
    for (final n in ['a.mp3', 'b.M4A', 'c.wma', 'd.m4p', 'e.jpg', 'f.mp3.bpm']) {
      await write(n, [0]);
    }
    expect((await scanMp3s(tmp.path)).map(baseName), ['a.mp3', 'b.M4A', 'c.wma']);
  });
}
