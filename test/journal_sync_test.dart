import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/services/mixtape/http_transport.dart';
import 'package:shared_core/services/mixtape/importer.dart';
import 'package:shared_core/services/mixtape/journal.dart';

void main() {
  late Directory tmp;
  late PlayJournal journal;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('journal_sync_');
    journal = PlayJournal(File(p.join(tmp.path, 'journal.jsonl')));
    for (var i = 0; i < 3; i++) {
      await journal.append(JournalEntry(
          type: JournalEntry.play, at: 1000 + i, device: 'ph1', title: 'Song $i', listened: 30, done: true));
    }
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<PushReceiver> receiver({bool callbacks = true}) async {
    final r = PushReceiver(
      importer: MixtapeImporter(Directory(p.join(tmp.path, 'music'))),
      staging: Directory(p.join(tmp.path, 'staging')),
      token: '123456',
      isTrusted: (t) => t == 'paired-token',
      journal: callbacks ? journal.since : null,
      ackJournal: callbacks ? journal.trimTo : null,
    );
    await r.start(port: 0);
    addTearDown(r.stop);
    return r;
  }

  Uri base(int port) => Uri.parse('http://127.0.0.1:$port');

  group('push journal routes', () {
    test('a paired PC reads entries since a seq and acks to trim', () async {
      final r = await receiver();
      final s = PushSender(base(r.port!), 'paired-token');
      final all = await s.journal();
      expect(all.map((e) => e.seq), [1, 2, 3]);
      expect(all.first.title, 'Song 0');
      expect(all.first.device, 'ph1');
      expect((await s.journal(since: 2)).map((e) => e.seq), [3]);

      await s.ackJournal(2);
      expect((await journal.since(0)).map((e) => e.seq), [3]);
      expect(await journal.lastSeq, 3);
    });

    test('the one-time session code cannot read or trim the journal', () async {
      final r = await receiver();
      final s = PushSender(base(r.port!), '123456');
      await s.hello(); // the code still works for sending
      await expectLater(s.journal(), throwsA(isA<TransferException>()));
      await expectLater(s.ackJournal(3), throwsA(isA<TransferException>()));
      expect((await journal.since(0)).length, 3);
    });

    test('a phone without journal sync answers 404: empty list, ack is a no-op', () async {
      final r = await receiver(callbacks: false);
      final s = PushSender(base(r.port!), 'paired-token');
      expect(await s.journal(), isEmpty);
      await s.ackJournal(3);
      expect((await journal.since(0)).length, 3);
    });
  });

  group('pull journal route', () {
    test('PullClient.sendJournal posts entries and gets the ack seq', () async {
      final got = <JournalEntry>[];
      final server = PullServer(
          root: tmp,
          token: '654321',
          onJournal: (entries) async {
            got.addAll(entries);
            return entries.last.seq;
          });
      await server.start(port: 0);
      addTearDown(server.stop);
      final c = PullClient(base(server.port!), '654321');
      final ack = await c.sendJournal(await journal.since(0));
      expect(ack, 3);
      expect(got.map((e) => e.title), ['Song 0', 'Song 1', 'Song 2']);
    });

    test('an older PC (no onJournal) gives null', () async {
      final server = PullServer(root: tmp, token: '654321');
      await server.start(port: 0);
      addTearDown(server.stop);
      final c = PullClient(base(server.port!), '654321');
      expect(await c.sendJournal(await journal.since(0)), isNull);
    });

    test('a wrong code is rejected', () async {
      final server = PullServer(root: tmp, token: '654321', onJournal: (e) async => 99);
      await server.start(port: 0);
      addTearDown(server.stop);
      final c = PullClient(base(server.port!), '000000');
      await expectLater(c.sendJournal(const []), throwsA(isA<TransferException>()));
    });
  });

  test('decodeJournalBody reads both the JSON body and JSONL', () async {
    final entries = await journal.since(0);
    expect(decodeJournalBody(encodeJournalBody(entries)).length, 3);
    expect(decodeJournalBody(await File(journal.file.path).readAsString()).length, 3);
  });
}
