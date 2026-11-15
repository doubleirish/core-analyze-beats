import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/models/step_plan.dart';
import 'package:shared_core/models/tempo.dart';
import 'package:shared_core/services/bpm_store.dart';
import 'package:shared_core/services/mixtape/discovery.dart';
import 'package:shared_core/services/mixtape/http_transport.dart';
import 'package:shared_core/services/mixtape/importer.dart';
import 'package:shared_core/services/mixtape/manifest.dart';
import 'package:shared_core/services/mixtape/package_writer.dart';
import 'package:shared_core/services/mixtape/transports.dart';
import 'package:shared_core/services/mixtape/usb_transport.dart';

const _ffmpeg = r'C:\Users\conor\dev\tools\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe';

void main() {
  late Directory tmp;
  late List<MixtapeSource> sources;
  late MixtapeImporter importer;
  final writer = PackageWriter();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mixtape_test');
    final rnd = Random(1);
    final lib = Directory(p.join(tmp.path, 'pc', 'deep', 'dir'))..createSync(recursive: true);
    sources = [];
    for (var i = 0; i < 3; i++) {
      final f = File(p.join(lib.path, 'src$i.mp3'))
        ..writeAsBytesSync(Uint8List.fromList(List.generate(5000 + i, (_) => rnd.nextInt(256))));
      sources.add(MixtapeSource(
        path: f.path,
        title: 'Title $i',
        artist: i == 2 ? 'A/B: "x"' : 'Artist',
        album: 'Album',
        duration: 100.0,
        rating: i,
        fav: i == 1,
        tags: ['gym'],
        lyrics: i == 0 ? '[00:01.00]hello' : null,
        art: i == 0 ? Uint8List.fromList([0xFF, 0xD8, 1, 2, 3]) : null,
        bpm: {
          'avg': 120.0,
          'segments': [
            {'start': 0.0, 'end': 50.0, 'bpm': 118.0},
            {'start': 50.0, 'end': 100.0, 'bpm': 122.0},
          ],
        },
      ));
    }
    importer = MixtapeImporter(Directory(p.join(tmp.path, 'phone')));
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Directory pc(String d) => Directory(p.join(tmp.path, 'pc_out', d));

  test('folder: flat names, sidecars, metadata, relative playlist', () async {
    final m = await FolderTransport.export(writer,
        id: 'gym1', name: 'Gym Mix', sources: sources, root: pc('x'));
    expect(m.tracks.map((t) => t.file).every((f) => f.startsWith('songs/') && !f.substring(6).contains('/')), true);
    expect(m.tracks[2].file, isNot(contains(':')));
    final pkg = labelDir(pc('x'), Transport.folder, 'gym1');
    final playlist = File(p.join(pkg.path, playlistName)).readAsStringSync();
    expect(playlist, contains('songs/001 - Artist - Title 0.mp3'));

    final found = await discoverPackages(pc('x'));
    expect(found, hasLength(1));
    final r = await importer.importPackage(found.first.dir);
    expect(r.errors, isEmpty);
    expect(r.paths, hasLength(3));
    expect(r.copied, 3);
    expect(r.paths.first, contains(p.join('phone', 'folder', 'Gym Mix [gym1]')));
    final first = r.paths.first;
    expect((await BpmStore.load(first))!.byAlgo[baselineId]!.segments, hasLength(2));
    expect(File('$first.lrc').readAsStringSync(), contains('hello'));
    expect(File('$first.jpg').existsSync(), true);
    final meta = (await SongMeta.load(r.paths[1]))!;
    expect(meta['fav'], true);
    expect(meta['rating'], 1);
    expect(meta['tags'], ['gym']);
    expect(await importer.alreadyImported(r.manifest), true);

    final again = await importer.importPackage(found.first.dir);
    expect(again.copied, 0);
    expect(again.reused, 3);
  });

  test('labels: same mix via two methods lands in separate label folders', () async {
    await FolderTransport.export(writer, id: 'same', name: 'Same', sources: sources, root: pc('l'));
    final zip = File(p.join(tmp.path, 'same$mixtapeFileExt'));
    await ZipTransport.export(writer,
        id: 'same', name: 'Same', sources: [sources[0]], zipFile: zip, cache: pc('lz'));
    final a = await importer.importPackage(labelDir(pc('l'), Transport.folder, 'same'));
    final b = await ZipTransport.import(zip, Directory(p.join(tmp.path, 'st')), importer);
    expect(p.split(a.paths.first), contains(Transport.folder));
    expect(p.split(b.paths.first), contains(Transport.zip));
    // The zip import (1 song) must not have deleted the folder import's songs.
    expect(a.paths.every((f) => File(f).existsSync()), true);
    expect(b.paths, hasLength(1));
  });

  test('stable id: rename moves the folder; names differing by case never collide', () async {
    final root = pc('r');
    await FolderTransport.export(writer, id: 'k1', name: 'Gym', sources: sources, root: root);
    final first = await importer.importPackage(labelDir(root, Transport.folder, 'k1'));
    final oldDir = File(first.paths.first).parent;

    await FolderTransport.export(writer, id: 'k1', name: 'Gym 2025', sources: sources, root: root);
    final renamed = await importer.importPackage(labelDir(root, Transport.folder, 'k1'));
    expect(renamed.reused, 3);
    expect(renamed.copied, 0);
    expect(oldDir.existsSync(), false);
    expect(p.basename(File(renamed.paths.first).parent.path), 'Gym 2025 [k1]');
    expect(File('${renamed.paths.first}.jpg').existsSync(), true);
    final m3u = File(renamed.paths.first).parent.listSync().whereType<File>()
        .where((f) => f.path.endsWith('.m3u8'));
    expect(m3u, hasLength(1));

    await FolderTransport.export(writer, id: 'k2', name: 'gym 2025', sources: [sources[1]], root: root);
    final other = await importer.importPackage(labelDir(root, Transport.folder, 'k2'));
    expect(File(other.paths.single).parent.path, isNot(File(renamed.paths.first).parent.path));
    expect(renamed.paths.every((f) => File(f).existsSync()), true);
  });

  test('incremental write reuses unchanged songs and drops removed ones', () async {
    final root = pc('inc');
    await FolderTransport.export(writer, id: 'inc', name: 'Inc', sources: sources, root: root);
    final pkg = labelDir(root, Transport.folder, 'inc');
    final first = File(p.join(pkg.path, 'songs', '001 - Artist - Title 0.mp3'));
    final stamp = first.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final m = await FolderTransport.export(writer,
        id: 'inc', name: 'Inc', sources: [sources[0], sources[1]], root: root);
    expect(first.lastModifiedSync(), stamp);
    expect(m.tracks, hasLength(2));
    expect(Directory(p.join(pkg.path, 'songs')).listSync(), hasLength(2));
  });

  test('corrupt file and missing manifest are rejected with clear errors', () async {
    await FolderTransport.export(writer, id: 'c', name: 'C', sources: sources, root: pc('c'));
    final pkg = labelDir(pc('c'), Transport.folder, 'c');
    File(p.join(pkg.path, 'songs', '002 - Artist - Title 1.mp3')).writeAsBytesSync([1, 2, 3]);
    expect(() => importer.importPackage(pkg), throwsA(isA<ImportException>()));
    expect(() => importer.importPackage(Directory(tmp.path)),
        throwsA(predicate((e) => e is ImportException && e.message.contains('Not a beats-me'))));
  });

  test('zip: round trip, and a package zipped one folder down still imports', () async {
    final zip = File(p.join(tmp.path, 'out', 'mix$mixtapeFileExt'));
    await ZipTransport.export(writer,
        id: 'z', name: 'Zipped', sources: sources, zipFile: zip, cache: pc('zc'));
    final r = await ZipTransport.import(zip, Directory(p.join(tmp.path, 'stage')), importer);
    expect(r.paths, hasLength(3));
    expect(r.errors, isEmpty);
    expect(File(r.paths.first).readAsBytesSync(), File(sources[0].path).readAsBytesSync());

    final nested = await ZipTransport.extract(zip, Directory(p.join(tmp.path, 'n1')));
    final wrapper = Directory(p.join(tmp.path, 'wrap'))..createSync();
    await Directory(nested.path).rename(p.join(wrapper.path, 'inner'));
    final found = await discoverPackages(wrapper);
    expect(found.single.manifest.id, 'z');
    expect(() => ZipTransport.extract(File(sources[0].path), Directory(p.join(tmp.path, 'bad'))),
        throwsA(isA<ImportException>()));
  });

  test('pull: QR link, wrong code, incremental download, done report', () async {
    final root = pc('pull');
    await writer.write(
        id: 'pm',
        name: 'Pull Me',
        transport: Transport.pull,
        sources: sources,
        out: labelDir(root, Transport.pull, 'pm'));
    final reports = <String, Map<String, dynamic>>{};
    final server = PullServer(
        root: root, token: '123456', name: 'PC', onPhoneDone: (id, r) => reports[id] = r);
    await server.start(port: 0);
    addTearDown(server.stop);

    final link = PullLink(hosts: ['10.255.255.1', '127.0.0.1'], port: server.port!, token: '123456', name: 'PC');
    final parsed = PullLink.parse(link.toString())!;
    expect(parsed.hosts, link.hosts);
    expect(parsed.port, server.port);
    expect(PullLink.parse('https://example.com'), isNull);

    final bad = PullLink(hosts: ['127.0.0.1'], port: server.port!, token: '000000');
    expect(() => PullClient.reach(bad),
        throwsA(predicate((e) => e is TransferException && e.kind == TransferError.auth)));
    final client = await PullClient.reach(parsed);
    expect(client.base.host, '127.0.0.1');
    final list = await client.list();
    expect(list.single.id, 'pm');
    expect(list.single.bytes, greaterThan(0));

    final stage = Directory(p.join(tmp.path, 'pstage'));
    var dir = await client.download('pm', stage, haveSong: importer.hasTrack);
    var r = await importer.importPackage(dir, move: true);
    expect(r.copied, 3);
    await client.reportDone('pm', {'copied': r.copied});
    expect(reports['pm']!['copied'], 3);

    await Directory(stage.path).delete(recursive: true);
    dir = await client.download('pm', stage, haveSong: importer.hasTrack);
    expect(Directory(p.join(dir.path, 'songs')).existsSync() &&
        Directory(p.join(dir.path, 'songs')).listSync().isNotEmpty, false);
    r = await importer.importPackage(dir, move: true);
    expect(r.reused, 3);
    expect(r.errors, isEmpty);
  });

  test('push: pairing, hello, only missing files, resume and damaged partials', () async {
    final results = <ImportResult>[];
    final trusted = <String>{};
    final recv = PushReceiver(
        importer: importer,
        staging: Directory(p.join(tmp.path, 'rstage')),
        token: '654321',
        deviceName: 'Pixel',
        deviceId: 'ph1',
        isTrusted: trusted.contains,
        freeBytes: () async => 12345,
        onPair: (req) async {
          if (req.code != '111111') return null;
          final t = newToken();
          trusted.add(t);
          return t;
        },
        onImported: results.add);
    await recv.start(port: 0);
    addTearDown(recv.stop);
    final base = Uri.parse('http://127.0.0.1:${recv.port}');

    expect(() => PushSender.pair(base, pcName: 'PC', pcId: 'pc1', code: '999999'),
        throwsA(predicate((e) => e is TransferException && e.kind == TransferError.declined)));
    final paired = await PushSender.pair(base, pcName: 'PC', pcId: 'pc1', code: '111111');
    expect(paired.name, 'Pixel');
    final sender = PushSender(base, paired.token);
    final hello = await sender.hello();
    expect(hello.freeBytes, 12345);
    expect(hello.id, 'ph1');
    expect(() => PushSender(base, 'bad').hello(),
        throwsA(predicate((e) => e is TransferException && e.kind == TransferError.auth)));

    final pkg = labelDir(pc('push'), Transport.push, 'pushed');
    final m = await writer.write(
        id: 'pushed', name: 'Pushed', transport: Transport.push, sources: sources, out: pkg);

    // A previous attempt left half of song 1 and a damaged half of song 2.
    final stage = p.join(tmp.path, 'rstage', 'pushed');
    final s1 = File(p.join(pkg.path, m.tracks[1].file)).readAsBytesSync();
    File(p.join(stage, '${m.tracks[1].file}.part'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(s1.sublist(0, 2000));
    File(p.join(stage, '${m.tracks[2].file}.part')).writeAsBytesSync(List.filled(1500, 7));

    final res = await sender.send(pkg);
    expect(res.errors, isEmpty);
    expect(results.single.paths, hasLength(3));
    for (var i = 0; i < 3; i++) {
      expect(File(results.single.paths[i]).readAsBytesSync(),
          File(p.join(pkg.path, m.tracks[i].file)).readAsBytesSync());
    }

    final res2 = await sender.send(pkg);
    expect(res2.sent, 0);

    final wrong = labelDir(pc('push2'), Transport.folder, 'w');
    await writer.write(id: 'w', name: 'W', transport: Transport.folder, sources: sources, out: wrong);
    expect(() => sender.send(wrong), throwsA(isA<TransferException>()));
  });

  test('connection refused gives advice, not a socket dump', () async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    try {
      await PushSender(Uri.parse('http://127.0.0.1:$port'), 'x').hello();
      fail('should throw');
    } on TransferException catch (e) {
      expect(e.message, contains('beats-me'));
    }
  });

  test('discovery: phone answers a broadcast query over loopback', () async {
    final responder = DiscoveryResponder(name: 'Pixel', id: 'ph1', port: () => 4242, listenPort: 0);
    await responder.start();
    addTearDown(responder.stop);
    final found = await discoverPhones(
        wait: const Duration(milliseconds: 600),
        port: responder.boundPort!,
        extraHosts: ['127.0.0.1']);
    final me = found.where((d) => d.id == 'ph1').single;
    expect(me.name, 'Pixel');
    expect(me.port, 4242);
  });

  test('syncdir: watcher imports only complete packages once', () async {
    final root = pc('sync');
    final pkg = labelDir(root, Transport.syncdir, 'synced');
    await writer.write(
        id: 'synced', name: 'Synced', transport: Transport.syncdir, sources: sources, out: pkg);
    final watcher = SyncdirWatcher(root, importer);
    final first = await watcher.scanOnce();
    expect(first, hasLength(1));
    expect(await watcher.scanOnce(), isEmpty);

    // A new song still being synced (truncated) must not trigger an import.
    final fresh = File(p.join(tmp.path, 'fresh.mp3'))..writeAsBytesSync(List.filled(4000, 9));
    final m = await writer.write(
        id: 'synced',
        name: 'Synced',
        transport: Transport.syncdir,
        sources: [MixtapeSource(path: fresh.path, title: 'Fresh')],
        out: pkg);
    File(p.join(pkg.path, m.tracks.single.file)).writeAsBytesSync(List.filled(10, 9));
    expect(await watcher.scanOnce(), isEmpty);
  });

  test('usb inbox: incremental package (installed songs absent) is imported and consumed', () async {
    final inbox = Directory(p.join(tmp.path, 'inbox'));
    final pkg = labelDir(inbox, Transport.usb, 'u1');
    final m = await writer.write(
        id: 'u1', name: 'Usb', transport: Transport.usb, sources: sources, out: pkg);
    final watcher = SyncdirWatcher(inbox, importer, label: null, consume: true);
    expect((await watcher.scanOnce()).single.copied, 3);
    expect(pkg.existsSync(), false);
    final shas = ((await importer.ledger())['usb:u1'] as Map)['shas'] as List;
    expect(shas, hasLength(3));

    // Second send: only song 0 changed on the PC, so only it is pushed.
    final m2 = await writer.write(
        id: 'u1', name: 'Usb', transport: Transport.usb, sources: sources, out: pkg);
    for (final t in m2.tracks.skip(1)) {
      File(p.join(pkg.path, t.file)).deleteSync();
    }
    expect(m2.tracks.map((t) => t.sha256), m.tracks.map((t) => t.sha256));
    final again = await watcher.scanOnce(force: true);
    expect(again.single.reused, 3);
    expect(pkg.existsSync(), false);
  });

  test('step: a track\'s program-part name round-trips into its .meta.json sidecar', () async {
    final f = File(p.join(tmp.path, 'step.mp3'))..writeAsBytesSync(List.filled(500, 3));
    final src = MixtapeSource(path: f.path, title: 'Step Song', artist: 'A', step: 'Climb');
    final root = pc('step');
    await FolderTransport.export(writer, id: 'step1', name: 'StepMix', sources: [src], root: root);
    final found = await discoverPackages(root);
    expect(found.single.manifest.tracks.single.step, 'Climb');
    final r = await importer.importPackage(found.single.dir);
    final meta = (await SongMeta.load(r.paths.single))!;
    expect(meta['step'], 'Climb');
  });

  test('damaged: a track\'s damage reason reaches the phone\'s .meta.json', () async {
    final f = File(p.join(tmp.path, 'bad.mp3'))..writeAsBytesSync(List.filled(500, 5));
    final src = MixtapeSource(path: f.path, title: 'Bad', artist: 'A', damaged: 'truncated');
    final root = pc('bad');
    await FolderTransport.export(writer, id: 'bad1', name: 'BadMix', sources: [src], root: root);
    final found = await discoverPackages(root);
    expect(found.single.manifest.tracks.single.damaged, 'truncated');
    final r = await importer.importPackage(found.single.dir);
    expect((await SongMeta.load(r.paths.single))!['damaged'], 'truncated');
  });

  test('plan: a track\'s sub-activity plan survives export and import', () async {
    final f = File(p.join(tmp.path, 'plan.mp3'))..writeAsBytesSync(List.filled(500, 4));
    const plan = StepPlan(activity: 'Tabata', icon: 'tabata', minRpm: 90, maxRpm: 105, segments: [
      StepSegment(label: 'Steady', start: 0, end: 15, minRpm: 90, maxRpm: 105, lead: true),
      StepSegment(label: 'Work', start: 15, end: 35, minRpm: 90, maxRpm: 105, cue: 'All out'),
    ]);
    final src = MixtapeSource(
        path: f.path, title: 'Plan Song', artist: 'A', step: 'Tabata', plan: plan.toJson());
    final root = pc('plan');
    await FolderTransport.export(writer, id: 'plan1', name: 'PlanMix', sources: [src], root: root);
    final found = await discoverPackages(root);
    final r = await importer.importPackage(found.single.dir);
    final meta = (await SongMeta.load(r.paths.single))!;
    final back = StepPlan.fromJson((meta['plan'] as Map).cast<String, dynamic>());
    expect(back.activity, 'Tabata');
    expect(back.segments.last.cue, 'All out');
    expect(back.segmentAt(20)!.label, 'Work');
  });

  test('adb output parsing', () {
    final d = parseAdbDevices('List of devices attached\n'
        'R58M123 device usb:1-1 product:x model:Pixel_7 device:y\n'
        'emulator-5554 unauthorized\n\n');
    expect(d, hasLength(2));
    expect(d[0].ready, true);
    expect(d[0].label, 'Pixel 7');
    expect(d[1].ready, false);
    expect(d[1].advice, contains('Allow'));
    expect(parseDfAvailable('Filesystem 1K-blocks Used Available Use% Mounted on\n'
        '/dev/fuse 100 40 60 40% /storage/emulated\n'), 60 * 1024);
  });

  test('auto transcode: copies playable files, converts others, warns without ffmpeg', () async {
    expect(TranscodePreset.resolve(TranscodePreset.autoId, 'a.mp3'), isNull);
    expect(TranscodePreset.resolve(TranscodePreset.autoId, 'a.FLAC'), isNull);
    expect(TranscodePreset.resolve(TranscodePreset.autoId, 'a.wma')!.id, TranscodePreset.autoTarget);
    expect(TranscodePreset.resolve('mp3-128', 'a.mp3')!.id, 'mp3-128');

    final aiff = File(p.join(tmp.path, 'x.aiff'))..writeAsBytesSync(List.filled(100, 1));
    final noFf = PackageWriter(ffmpegPath: null);
    final m = await noFf.write(
        id: 'a',
        name: 'A',
        transport: Transport.folder,
        sources: [MixtapeSource(path: aiff.path, title: 'X')],
        out: pc('a'),
        transcodeId: TranscodePreset.autoId);
    expect(m.tracks.single.file, endsWith('.aiff'));
    expect(noFf.warnings.single, contains('x.aiff'));
    expect(
        () => noFf.write(
            id: 'b',
            name: 'B',
            transport: Transport.folder,
            sources: [MixtapeSource(path: aiff.path)],
            out: pc('b'),
            transcodeId: 'mp3-128'),
        throwsA(isA<PackageException>()));
  });

  test('transcode shrinks wav to mp3 and records the preset', () async {
    if (!File(_ffmpeg).existsSync()) return;
    final wav = File(p.join(tmp.path, 'tone.wav'));
    final gen = await Process.run(_ffmpeg,
        ['-y', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3', wav.path]);
    expect(gen.exitCode, 0);
    final m = await PackageWriter(ffmpegPath: _ffmpeg).write(
        id: 't',
        name: 'T',
        transport: Transport.folder,
        sources: [MixtapeSource(path: wav.path, title: 'Tone', artist: 'Sine')],
        out: pc('t'),
        transcodeId: 'mp3-128');
    expect(m.tracks.single.file, endsWith('.mp3'));
    expect(m.tracks.single.transcode, 'mp3-128');
    expect(m.tracks.single.size, lessThan(wav.lengthSync()));
  });

  test('safeRelative blocks traversal; ids are random', () {
    expect(safeRelative('songs/a.mp3'), true);
    expect(safeRelative('../x'), false);
    expect(safeRelative('songs/../../x'), false);
    expect(safeRelative('/abs'), false);
    expect(safeRelative('C:/x'), false);
    expect(safeRelative('a\\b'), false);
    expect(newMixtapeId(), isNot(newMixtapeId()));
  });
}
