import 'dart:convert';

import 'package:crypto/crypto.dart';

const albumCatalogName = 'albums.json';
const maxAlbumCatalogBytes = 8 * 1024 * 1024;

/// Keep edition names and non-Latin letters: different releases can have
/// different track lists even when their base titles match.
String normalizeCatalogText(String text) => text
    .toLowerCase()
    .replaceAll('&', ' and ')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

class CatalogAlbum {
  const CatalogAlbum({
    required this.key,
    required this.artist,
    required this.album,
    required this.have,
    this.total,
    this.incomplete = false,
  });

  final String key, artist, album;
  final int have;
  final int? total;
  final bool incomplete;

  Map<String, Object?> toJson() => {
    'key': key,
    'artist': artist,
    'album': album,
    'have': have,
    'total': total,
    'incomplete': incomplete,
  };
}

class AlbumCatalog {
  AlbumCatalog({required this.generatedAt, required List<CatalogAlbum> albums})
    : albums = List.unmodifiable(albums);

  final DateTime generatedAt;
  final List<CatalogAlbum> albums;

  String get fingerprint =>
      sha256.convert(utf8.encode(jsonEncode([for (final a in albums) a.toJson()]))).toString();

  String encode() {
    final text = jsonEncode({
      'version': 1,
      'generatedAt': generatedAt.toUtc().millisecondsSinceEpoch,
      'albums': [for (final a in albums) a.toJson()],
    });
    if (utf8.encode(text).length > maxAlbumCatalogBytes) {
      throw const FormatException('Album catalogue exceeds 8 MB.');
    }
    return text;
  }

  static AlbumCatalog decode(String text) {
    if (utf8.encode(text).length > maxAlbumCatalogBytes) {
      throw const FormatException('Album catalogue exceeds 8 MB.');
    }
    final j = jsonDecode(text);
    if (j is! Map<String, dynamic> ||
        j['version'] != 1 ||
        j['generatedAt'] is! int ||
        j['generatedAt'] < 0 ||
        j['generatedAt'] > 8640000000000000 ||
        j['albums'] is! List) {
      throw const FormatException('Invalid or unsupported album catalogue.');
    }
    final albums = <CatalogAlbum>[];
    final keys = <String>{};
    for (final row in j['albums'] as List) {
      if (row is! Map<String, dynamic>) {
        throw const FormatException('Invalid catalogue album.');
      }
      final key = row['key'], artist = row['artist'], album = row['album'];
      final have = row['have'], total = row['total'], incomplete = row['incomplete'];
      if (key is! String ||
          key.isEmpty ||
          key.length > 2048 ||
          !keys.add(key) ||
          artist is! String ||
          artist.length > 1024 ||
          album is! String ||
          album.trim().isEmpty ||
          album.length > 1024 ||
          have is! int ||
          have < 0 ||
          (total != null && (total is! int || total < have || total < 1)) ||
          incomplete is! bool ||
          (total is int && total > have && !incomplete)) {
        throw const FormatException('Invalid catalogue album fields.');
      }
      albums.add(
        CatalogAlbum(
          key: key,
          artist: artist,
          album: album,
          have: have,
          total: total as int?,
          incomplete: incomplete,
        ),
      );
    }
    return AlbumCatalog(
      generatedAt: DateTime.fromMillisecondsSinceEpoch(j['generatedAt'] as int, isUtc: true),
      albums: albums,
    );
  }

  List<CatalogAlbum> search(String query) {
    final q = normalizeCatalogText(query);
    final tokens = q.split(' ').where((t) => t.isNotEmpty).toList();
    String text(CatalogAlbum a) => normalizeCatalogText('${a.artist} ${a.album}');
    int rank(CatalogAlbum a) {
      final title = normalizeCatalogText(a.album), artist = normalizeCatalogText(a.artist);
      if (q == title || q == artist || q == text(a)) return 0;
      if (title.startsWith(q) || artist.startsWith(q) || text(a).startsWith(q)) {
        return 1;
      }
      return 2;
    }

    return albums.where((a) => tokens.every(text(a).contains)).toList()..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final artist = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
      return artist != 0 ? artist : a.album.toLowerCase().compareTo(b.album.toLowerCase());
    });
  }
}
