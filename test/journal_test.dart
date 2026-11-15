import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_core/services/mixtape/journal.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('journal_'));
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  File f(String name) => File('${tmp.path}${Platform.pathSeparator}$name');
  JournalEntry play(double s) =>
      JournalEntry.forPlay(device: 'dev1', listened: s, done: s > 100, at: 1000);

  test('append assigns seqs; since and trimTo keep the counter', () async {
    final j = PlayJournal(f('j.jsonl'));
    expect(await j.lastSeq, 0);
    final a = await j.append(play(10));
    final b = await j.append(play(20));
    await j.append(play(30));
    expect([a.seq, b.seq], [1, 2]);
    expect((await j.since(1)).map((e) => e.seq), [2, 3]);

    await j.trimTo(3);
    expect(await j.since(0), isEmpty);
    expect((await j.append(play(40))).seq, 4);

    final reopened = PlayJournal(f('j.jsonl'));
    expect(await reopened.lastSeq, 4);
    await reopened.trimTo(4);
    final again = PlayJournal(f('j.jsonl'));
    expect((await again.append(play(50))).seq, 5);
    expect((await again.since(0)).single.listened, 50);
  });

  test('concurrent appends get unique ordered seqs', () async {
    final j = PlayJournal(f('j.jsonl'));
    final out = await Future.wait([for (var i = 0; i < 25; i++) j.append(play(i.toDouble()))]);
    expect(out.map((e) => e.seq), List.generate(25, (i) => i + 1));
    final all = await j.since(0);
    expect(all.map((e) => e.listened), List.generate(25, (i) => i.toDouble()));
  });

  test('corrupt lines are skipped and the seq is derived from the file', () async {
    final e = play(5).withSeq(7);
    await f('j.jsonl').writeAsString('${jsonEncode(e.toJson())}\n{not json\n{"seq":"x"}\n');
    final j = PlayJournal(f('j.jsonl'));
    expect((await j.since(0)).map((e) => e.seq), [7]);
    expect((await j.append(play(6))).seq, 8);
  });

  test('mirror holds the whole current journal', () async {
    final m = f('sub${Platform.pathSeparator}mirror.jsonl');
    final j = PlayJournal(f('j.jsonl'), mirror: m);
    await j.append(play(1));
    await j.append(play(2));
    expect(parseJournal(await m.readAsString()).map((e) => e.seq), [1, 2]);
    await j.trimTo(1);
    expect(parseJournal(await m.readAsString()).map((e) => e.seq), [2]);
  });

  test('entries are built from song meta and round-trip through parseJournal', () async {
    final song = f('song.mp3');
    await song.writeAsString('x');
    await File('${song.path}.meta.json').writeAsString(jsonEncode({
      'origPath': r'C:\Music\a.mp3',
      'sha256': 'abc',
      'title': 'T',
      'artist': 'A',
      'duration': 200,
      'mixId': 'm1',
      'other': 1,
    }));
    final j = PlayJournal(f('j.jsonl'));
    await j.append(await JournalEntry.playOf(song.path, device: 'd', listened: 190.5, done: true));
    await j.append(await JournalEntry.rateOf(song.path, device: 'd', rating: 9, fav: true));
    await j.append(await JournalEntry.playOf(f('none.mp3').path, device: 'd', listened: 1, done: false));

    final parsed = parseJournal(await f('j.jsonl').readAsString());
    expect(parsed.length, 3);
    final p = parsed[0];
    expect([p.type, p.origPath, p.sha256, p.title, p.artist, p.duration, p.mixId, p.listened, p.done],
        ['play', r'C:\Music\a.mp3', 'abc', 'T', 'A', 200.0, 'm1', 190.5, true]);
    final r = parsed[1];
    expect([r.type, r.sha256, r.rating, r.fav, r.listened], ['rate', 'abc', 5, true, null]);
    final bare = parsed[2];
    expect([bare.origPath, bare.sha256, bare.path], [null, null, f('none.mp3').path]);
    expect(parsed.map((e) => e.toJson()).toList(),
        (await j.since(0)).map((e) => e.toJson()).toList());
  });

  test('journal ack round-trips and rejects junk', () {
    expect(jsonDecode(ackJson(42, at: 7)), {'upTo': 42, 'at': 7});
    expect(parseAck(ackJson(42)), 42);
    expect(parseAck('{"upTo": 3.0}'), 3);
    for (final bad in ['', 'nope', '[]', '{}', '{"upTo": "5"}', '{"upTo": -1}']) {
      expect(parseAck(bad), isNull, reason: bad);
    }
  });
}
