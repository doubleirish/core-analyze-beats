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
import 'package:shared_core/services/mixtape/usb_transport.dart';

void main() {
  late Directory tmp;
  late List<MixtapeSource> sources;
  late MixtapeImporter importer;
  final writer = PackageWriter();
  final art = Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3, 4]);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('reuse_songs_test');
    final rnd = Random(11);
    final lib = Directory(p.join(tmp.path, 'pc', 'lib'))..createSync(recursive: true);
    sources = [
      for (var i = 0; i < 3; i++)
        MixtapeSource(
          path: (File(p.join(lib.path, 'src$i.mp3'))
                ..writeAsBytesSync(
                    Uint8List.fromList(List.generate(3000 + i, (_) => rnd.nextInt(256)))))
              .path,
          title: 'Title $i',
          duration: 60.0,
        ),
    ];
    importer = MixtapeImporter(Directory(p.join(tmp.path, 'phone')));
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  MixtapeSource withArt(MixtapeSource s) =>
      MixtapeSource(path: s.path, title: s.title, duration: s.duration, art: art);

  Future<Directory> export(String id, String name, List<MixtapeSource> srcs) async {
    final root = Directory(p.join(tmp.path, 'pc_out', id));
    await FolderTransport.export(writer, id: id, name: name, sources: srcs, root: root);
    return labelDir(root, Transport.folder, id);
  }

  Future<ImportResult> install(String id, String name, List<MixtapeSource> srcs) async {
    final r = await importer.importPackage(await export(id, name, srcs));
    expect(r.errors, isEmpty);
    return r;
  }

  /// Exports mix B and deletes the song files (and optionally art) of the
  /// tracks at [omit] from the package, like an incremental send would.
  Future<(Directory, MixtapeManifest)> partial(List<MixtapeSource> srcs, List<int> omit,
      {bool omitArt = false}) async {
    final pkg = await export('mixB', 'Mix B', srcs);
    final m = await MixtapeImporter.readManifest(pkg);
    for (final i in omit) {
      File(p.join(pkg.path, m.tracks[i].file)).deleteSync();
      final artFile = m.tracks[i].art == null ? null : File(p.join(pkg.path, m.tracks[i].art!));
      if (omitArt && artFile != null && artFile.existsSync()) artFile.deleteSync();
    }
    return (pkg, m);
  }

  test('songs installed for another mix are verified and copied, not resent', () async {
    final a = await install('mixA', 'Mix A', sources.sublist(0, 2));
    final (pkg, m) = await partial([sources[1], sources[2]], [0]);

    expect(await importer.hasTrack(m, m.tracks[0]), isTrue);
    expect(await importer.hasTrack(m, m.tracks[1]), isFalse);
    expect(await importer.verify(pkg, m), isEmpty);

    final b = await importer.importPackage(pkg, move: true);
    expect(b.errors, isEmpty);
    expect((b.copied, b.reused, b.reusedOther), (1, 0, 1));
    expect(await fileMatches(File(b.paths[0]), m.tracks[0].size, m.tracks[0].sha256), isTrue);
    // A keeps its own file.
    expect(await fileMatches(File(a.paths[1]), m.tracks[0].size, m.tracks[0].sha256), isTrue);
    expect(p.equals(a.paths[1], b.paths[0]), isFalse);
  });

  test('a corrupted copy in another mix is not reused', () async {
    final a = await install('mixA', 'Mix A', sources.sublist(0, 2));
    final (pkg, m) = await partial([sources[0], sources[1]], [0, 1]);

    // Same size, different bytes; and a truncated file.
    final f0 = File(a.paths[0]);
    final bytes = f0.readAsBytesSync()..[10] ^= 0xFF;
    f0.writeAsBytesSync(bytes);
    File(a.paths[1]).writeAsBytesSync([1, 2, 3]);

    expect(await importer.hasTrack(m, m.tracks[0]), isFalse);
    expect(await importer.hasTrack(m, m.tracks[0], checkHash: false), isTrue);
    expect(await importer.hasTrack(m, m.tracks[1], checkHash: false), isFalse);
    expect(await importer.verify(pkg, m), [m.tracks[0].file, m.tracks[1].file]);
    expect(() => importer.importPackage(pkg), throwsA(isA<ImportException>()));
  });

  test('deleting the source mix leaves the reusing mix intact', () async {
    final a = await install('mixA', 'Mix A', sources);
    final (pkg, m) = await partial(sources, [0, 1, 2]);
    final b = await importer.importPackage(pkg);
    expect(b.reusedOther, 3);

    File(a.paths.first).parent.deleteSync(recursive: true);
    for (var i = 0; i < 3; i++) {
      expect(await fileMatches(File(b.paths[i]), m.tracks[i].size, m.tracks[i].sha256), isTrue);
    }
    expect(await importer.verify(pkg, m), isEmpty);
  });

  test('cover art comes from the other copy or the package', () async {
    // Song 0 has art in A; song 1 doesn't.
    await install('mixA', 'Mix A', [withArt(sources[0]), sources[1]]);

    var (pkg, m) = await partial([withArt(sources[0]), withArt(sources[1])], [0, 1], omitArt: true);
    expect(await importer.hasTrack(m, m.tracks[0]), isTrue);
    expect(await importer.hasTrack(m, m.tracks[1]), isFalse);
    expect(await importer.hasSong(m, m.tracks[1]), isTrue);
    // Song 1's art is nowhere: it can't be completed.
    expect(await importer.verify(pkg, m), [m.tracks[1].file]);

    (pkg, m) = await partial([withArt(sources[0]), withArt(sources[1])], [0, 1]);
    expect(await importer.verify(pkg, m), isEmpty);
    final b = await importer.importPackage(pkg);
    expect(b.errors, isEmpty);
    expect(b.reusedOther, 2);
    for (final s in b.paths) {
      expect(File('$s.jpg').readAsBytesSync(), art);
    }
  });

  test('inventoryShas unions every mix or reads one', () {
    final out = jsonEncode({
      'folder:a': {'createdAt': 1, 'shas': ['x', 'y']},
      'usb:b': {'createdAt': 2, 'shas': ['y', 'z']},
      'push:c': {'createdAt': 3},
      'bad': 'nope',
    });
    expect(inventoryShas(out), {'x', 'y', 'z'});
    expect(inventoryShas(out, 'usb:b'), {'y', 'z'});
    expect(inventoryShas(out, 'pull:none'), isEmpty);
    expect(inventoryShas('cat: No such file or directory'), isEmpty);
    expect(inventoryShas(''), isEmpty);
  });
}
