import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/services/mixtape/importer.dart';
import 'package:shared_core/services/mixtape/manifest.dart';
import 'package:shared_core/services/mixtape/package_writer.dart';
import 'package:shared_core/services/mixtape/transports.dart';

void main() {
  late Directory tmp;
  late List<MixtapeSource> sources;
  late MixtapeImporter importer;
  final writer = PackageWriter();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meta_origin_test');
    final rnd = Random(7);
    final lib = Directory(p.join(tmp.path, 'pc', 'lib'))..createSync(recursive: true);
    sources = [
      for (var i = 0; i < 3; i++)
        MixtapeSource(
          path: (File(p.join(lib.path, 'src$i.mp3'))
                ..writeAsBytesSync(
                    Uint8List.fromList(List.generate(4000 + i, (_) => rnd.nextInt(256)))))
              .path,
          title: 'Title $i',
          artist: 'Artist',
          duration: 90.0,
        ),
    ];
    importer = MixtapeImporter(Directory(p.join(tmp.path, 'phone')));
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<ImportResult> install(String id, String name, List<MixtapeSource> srcs) async {
    final root = Directory(p.join(tmp.path, 'pc_out', id));
    await FolderTransport.export(writer, id: id, name: name, sources: srcs, root: root);
    final r = await importer.importPackage(labelDir(root, Transport.folder, id));
    expect(r.errors, isEmpty);
    return r;
  }

  File ledgerFile() => File(p.join(importer.destRoot.path, '.imported.json'));

  test('meta.json links each song to its PC file, sha and mix', () async {
    final r = await install('mixA', 'Mix A', sources);
    for (var i = 0; i < 3; i++) {
      final meta = (await SongMeta.load(r.paths[i]))!;
      expect(meta['origPath'], sources[i].path);
      expect(meta['sha256'], r.manifest.tracks[i].sha256);
      expect(meta['sha256'], await sha256OfFile(File(r.paths[i])));
      expect(meta['mixId'], 'mixA');
      expect(meta['transport'], Transport.folder);
      expect(meta['title'], 'Title $i');
    }
  });

  test('ledger stores song basenames parallel to shas', () async {
    final r = await install('mixA', 'Mix A', sources);
    final e = (await importer.ledger())['${Transport.folder}:mixA'] as Map;
    expect(e['files'], [for (final f in r.paths) p.basename(f)]);
    expect(e['shas'], [for (final t in r.manifest.tracks) t.sha256]);
  });

  test('installedTracks/installedBySha cover every mix, first file wins', () async {
    final a = await install('mixA', 'Mix A', sources);
    final b = await install('mixB', 'Mix B', [sources[2]]);

    final all = await importer.installedTracks();
    expect(all.map((t) => t.file.path), [...a.paths, ...b.paths]);
    expect(all.map((t) => t.sha256), [
      for (final t in [...a.manifest.tracks, ...b.manifest.tracks]) t.sha256
    ]);
    expect(all.last.mix, '${Transport.folder}:mixB');

    final bySha = await importer.installedBySha();
    expect(bySha, hasLength(3));
    expect(bySha[b.manifest.tracks.single.sha256]!.path, a.paths[2]);
  });

  test('old ledger entries without files fall back to the playlist', () async {
    final a = await install('mixA', 'Mix A', sources);
    final expected = (await importer.installedTracks())
        .map((t) => (t.sha256, t.file.path))
        .toList();

    final led = (jsonDecode(ledgerFile().readAsStringSync()) as Map).cast<String, dynamic>();
    (led['${Transport.folder}:mixA'] as Map).remove('files');
    ledgerFile().writeAsStringSync(jsonEncode(led));

    final old = await importer.installedTracks();
    expect(old.map((t) => (t.sha256, t.file.path)).toList(), expected);
    expect(old, hasLength(a.paths.length));

    // A playlist that no longer matches the shas is ignored, not misaligned.
    final m3u = File(a.paths.first).parent.listSync().whereType<File>()
        .singleWhere((f) => f.path.endsWith('.m3u8'));
    m3u.writeAsStringSync('#EXTM3U\n${p.basename(a.paths.first)}\n');
    expect(await importer.installedTracks(), isEmpty);
  });

  test('deleted songs and folders are skipped', () async {
    final a = await install('mixA', 'Mix A', sources);
    final b = await install('mixB', 'Mix B', [sources[2]]);
    File(a.paths[2]).deleteSync();

    var bySha = await importer.installedBySha();
    expect(bySha[a.manifest.tracks[2].sha256]!.path, b.paths.single);
    expect((await importer.installedTracks()).map((t) => t.file.path),
        [a.paths[0], a.paths[1], b.paths.single]);

    File(b.paths.single).parent.deleteSync(recursive: true);
    bySha = await importer.installedBySha();
    expect(bySha.keys, [a.manifest.tracks[0].sha256, a.manifest.tracks[1].sha256]);
  });
}
