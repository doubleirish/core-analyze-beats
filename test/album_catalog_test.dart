import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_core/shared_core.dart';

void main() {
  final catalog = AlbumCatalog(
    generatedAt: DateTime.utc(2026, 11, 7),
    albums: const [
      CatalogAlbum(key: 'band|moon', artist: 'Band', album: 'Moon', have: 3, total: 3),
      CatalogAlbum(
        key: 'band|moon deluxe',
        artist: 'Band',
        album: 'Moon (Deluxe)',
        have: 3,
        total: 5,
        incomplete: true,
      ),
      CatalogAlbum(key: 'other|blue moon', artist: 'Other', album: 'Blue Moon', have: 1),
      CatalogAlbum(
        key: 'various|cafe',
        artist: 'Various artists',
        album: 'Caf\u00e9 & \u97f3\u697d',
        have: 1,
        incomplete: true,
      ),
    ],
  );

  test('round trip retains unknown counts and missing-disc flag', () {
    final decoded = AlbumCatalog.decode(catalog.encode());
    expect(decoded.generatedAt, catalog.generatedAt);
    expect(decoded.albums.last.total, isNull);
    expect(decoded.albums.last.incomplete, isTrue);
    expect(decoded.fingerprint, catalog.fingerprint);
    expect(
      AlbumCatalog(generatedAt: DateTime.utc(2030), albums: catalog.albums).fingerprint,
      catalog.fingerprint,
    );
  });

  test('search matches artist and album tokens, exact first, preserves Unicode and editions', () {
    expect(catalog.search('moon').map((a) => a.album), ['Moon', 'Moon (Deluxe)', 'Blue Moon']);
    expect(catalog.search('DELUXE band').single.album, 'Moon (Deluxe)');
    expect(catalog.search('band other'), isEmpty);
    expect(catalog.search(' \u97f3\u697d & caf\u00e9 ').single.artist, 'Various artists');
  });

  test('rejects bad schema, duplicates and inconsistent track counts', () {
    final body = jsonDecode(catalog.encode()) as Map<String, dynamic>;
    for (final bad in [
      {...body, 'version': 2},
      {...body, 'generatedAt': -1},
      {...body, 'albums': 'not a list'},
      {
        ...body,
        'albums': [catalog.albums.first.toJson(), catalog.albums.first.toJson()],
      },
      {
        ...body,
        'albums': [
          {...catalog.albums.first.toJson(), 'have': -1},
        ],
      },
      {
        ...body,
        'albums': [
          {...catalog.albums.first.toJson(), 'have': 7},
        ],
      },
      {
        ...body,
        'albums': [
          {...catalog.albums.first.toJson(), 'total': 9},
        ],
      },
    ]) {
      expect(() => AlbumCatalog.decode(jsonEncode(bad)), throwsFormatException);
    }
  });

  test('USB stages, renames and starts import; only metadata is sent', () async {
    final commands = <List<String>>[];
    File? local;
    final usb = UsbTransport(
      'adb',
      run: (args) async {
        commands.add(args);
        if (args[2] == 'push') {
          local = File(args[3]);
          expect(AlbumCatalog.decode(await local!.readAsString()).fingerprint, catalog.fingerprint);
          expect(args.last, startsWith('$phoneInbox/$albumCatalogName.'));
          expect(args.last, endsWith('.tmp'));
        }
        return ProcessResult(0, 0, '', '');
      },
    );
    await usb.sendCatalog('phone', catalog);
    expect(commands.map((a) => a[2]), ['shell', 'push', 'shell', 'shell']);
    expect(commands[2][3], 'mv');
    expect(commands[2].last, "'$phoneInbox/$albumCatalogName'");
    expect(commands.last, contains(importInboxAction));
    expect(await local!.exists(), isFalse);
  });

  test('USB copy failure does not publish or launch a partial snapshot', () async {
    final commands = <List<String>>[];
    final usb = UsbTransport(
      'adb',
      run: (args) async {
        commands.add(args);
        return ProcessResult(0, args[2] == 'push' ? 1 : 0, '', 'copy failed');
      },
    );
    await expectLater(usb.sendCatalog('phone', catalog), throwsA(isA<TransferException>()));
    expect(commands.length, 2);
  });

  group('push catalogue route', () {
    late Directory dir;
    late PushReceiver receiver;
    AlbumCatalog? received;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('catalog-push-');
      received = null;
      receiver = PushReceiver(
        importer: MixtapeImporter(Directory(p.join(dir.path, 'music'))),
        staging: Directory(p.join(dir.path, 'staging')),
        token: '123456',
        isTrusted: (t) => t == 'trusted',
        onCatalog: (c) async => received = c,
      );
      await receiver.start(port: 0);
    });
    tearDown(() async {
      await receiver.stop();
      await dir.delete(recursive: true);
    });
    PushSender sender(String token) =>
        PushSender(Uri.parse('http://127.0.0.1:${receiver.port}'), token);

    test('paired sender receives confirmation only after storage callback', () async {
      expect((await sender('trusted').hello()).catalog, isTrue);
      await sender('trusted').sendCatalog(catalog);
      expect(received!.fingerprint, catalog.fingerprint);
    });

    test('rejects session codes and untrusted tokens without storing', () async {
      for (final token in ['123456', 'wrong']) {
        await expectLater(sender(token).sendCatalog(catalog), throwsA(isA<TransferException>()));
      }
      expect(received, isNull);
    });

    Future<int> request(List<int> bytes) async {
      final client = HttpClient();
      try {
        final req = await client.putUrl(
          Uri.parse('http://127.0.0.1:${receiver.port}/push/v1/catalog'),
        );
        req.headers.set('x-token', 'trusted');
        req.contentLength = bytes.length;
        req.add(bytes);
        final response = await req.close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close(force: true);
      }
    }

    test('malformed and oversized bodies never replace the catalogue', () async {
      expect(await request(utf8.encode('{"version":1}')), 400);
      expect(await request(List.filled(maxAlbumCatalogBytes + 1, 32)), 413);
      expect(received, isNull);
    });

    test('missing callback advertises no support and reports update required', () async {
      await receiver.stop();
      receiver = PushReceiver(
        importer: MixtapeImporter(Directory(p.join(dir.path, 'music'))),
        staging: Directory(p.join(dir.path, 'staging')),
        isTrusted: (t) => t == 'trusted',
      );
      await receiver.start(port: 0);
      expect((await sender('trusted').hello()).catalog, isFalse);
      await expectLater(
        sender('trusted').sendCatalog(catalog),
        throwsA(
          isA<TransferException>().having((e) => e.message, 'message', contains('Update beats-me')),
        ),
      );
    });

    test('failed persistence is not acknowledged', () async {
      await receiver.stop();
      receiver = PushReceiver(
        importer: MixtapeImporter(Directory(p.join(dir.path, 'music'))),
        staging: Directory(p.join(dir.path, 'staging')),
        isTrusted: (t) => t == 'trusted',
        onCatalog: (_) async => throw const FileSystemException('disk full'),
      );
      await receiver.start(port: 0);
      await expectLater(sender('trusted').sendCatalog(catalog), throwsA(isA<TransferException>()));
    });
  });
}
