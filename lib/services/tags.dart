import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'container_tags.dart';
import 'library_service.dart';

class TrackTags {
  const TrackTags(
      {this.title,
      this.artist,
      this.album,
      this.picture,
      this.lyrics,
      this.genre,
      this.year,
      this.trackNo,
      this.trackTotal,
      this.discNo,
      this.discTotal});

  final int? trackNo;
  final int? trackTotal;
  final int? discNo;
  final int? discTotal;
  final String? title;
  final String? artist;
  final String? album;
  final Uint8List? picture;
  final String? lyrics;
  final String? genre;
  final int? year;

  TrackTags withFallback(TrackTags o) => TrackTags(
        title: title ?? o.title,
        artist: artist ?? o.artist,
        album: album ?? o.album,
        picture: picture ?? o.picture,
        lyrics: lyrics ?? o.lyrics,
        genre: genre ?? o.genre,
        year: year ?? o.year,
        trackNo: trackNo ?? o.trackNo,
        trackTotal: trackTotal ?? o.trackTotal,
        discNo: discNo ?? o.discNo,
        discTotal: discTotal ?? o.discTotal,
      );
}

/// "Artist - Title.mp3" -> tags; otherwise the whole name is the title.
TrackTags tagsFromFilename(String path) {
  var name = baseName(path);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.replaceFirst(RegExp(r'^\d{1,3}\s*[-._)]\s*'), '');
  final i = name.indexOf(' - ');
  if (i > 0) {
    return TrackTags(
        artist: name.substring(0, i).trim(), title: name.substring(i + 3).trim());
  }
  return TrackTags(title: name.trim());
}

/// Reads ID3v2 tags; empty on any problem. Filename fills missing fields.
Future<TrackTags> readTags(String path) async {
  final c = await readContainerTags(path);
  if (c != null) {
    return TrackTags(
      title: c.title,
      artist: c.artist,
      album: c.album,
      picture: c.picture,
      lyrics: c.lyrics,
      genre: c.genre,
      year: c.year,
      trackNo: c.trackNo,
      trackTotal: c.trackTotal,
      discNo: c.discNo,
      discTotal: c.discTotal,
    ).withFallback(tagsFromFilename(path));
  }
  TrackTags id3 = const TrackTags();
  try {
    final raf = await File(path).open();
    try {
      final head = await raf.read(10);
      if (head.length == 10 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
        final size = _syncsafe(head, 6);
        if (size > 0 && size < 64 * 1024 * 1024) {
          final body = await raf.read(size);
          id3 = parseId3v2(head, body);
        }
      }
    } finally {
      await raf.close();
    }
  } catch (_) {}
  return id3.withFallback(tagsFromFilename(path));
}

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

TrackTags parseId3v2(Uint8List head, Uint8List body) {
  final ver = head[3];
  final flags = head[5];
  var data = body;
  if (flags & 0x80 != 0) data = _deunsync(data);
  var pos = 0;
  if (flags & 0x40 != 0 && data.length >= 4) {
    final ext = ver == 4
        ? _syncsafe(data, 0)
        : ((data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3]) + 4;
    pos = ext;
  }
  String? title, artist, album, lyrics, genre;
  int? year;
  (int?, int?) trck = (null, null), tpos = (null, null);
  Uint8List? picture;
  while (pos + 10 <= data.length) {
    final id = String.fromCharCodes(data.sublist(pos, pos + 4));
    if (id.codeUnitAt(0) == 0) break;
    final sz = ver == 4
        ? _syncsafe(data, pos + 4)
        : (data[pos + 4] << 24) | (data[pos + 5] << 16) | (data[pos + 6] << 8) | data[pos + 7];
    final start = pos + 10;
    if (sz < 0 || start + sz > data.length) break;
    final frame = Uint8List.sublistView(data, start, start + sz);
    switch (id) {
      case 'TIT2':
        title = _text(frame);
      case 'TPE1':
        artist = _text(frame);
      case 'TALB':
        album = _text(frame);
      case 'TCON':
        genre = _genre(_text(frame));
      case 'TRCK':
        trck = parseNofM(_text(frame));
      case 'TPOS':
        tpos = parseNofM(_text(frame));
      case 'TYER':
      case 'TDRC':
      case 'TORY':
      case 'TDOR':
        final m = RegExp(r'\d{4}').firstMatch(_text(frame) ?? '');
        if (m != null && year == null) year = int.parse(m.group(0)!);
      case 'USLT':
        lyrics = _uslt(frame);
      case 'APIC':
        picture ??= _apic(frame);
    }
    pos = start + sz;
  }
  return TrackTags(
      title: title,
      artist: artist,
      album: album,
      picture: picture,
      lyrics: lyrics,
      genre: genre,
      year: year,
      trackNo: trck.$1,
      trackTotal: trck.$2,
      discNo: tpos.$1,
      discTotal: tpos.$2);
}

const _id3v1Genres = {
  0: 'Blues', 1: 'Classic Rock', 2: 'Country', 3: 'Dance', 4: 'Disco', 5: 'Funk',
  6: 'Grunge', 7: 'Hip-Hop', 8: 'Jazz', 9: 'Metal', 10: 'New Age', 11: 'Oldies',
  12: 'Other', 13: 'Pop', 14: 'R&B', 15: 'Rap', 16: 'Reggae', 17: 'Rock',
  18: 'Techno', 19: 'Industrial', 20: 'Alternative', 21: 'Ska', 22: 'Death Metal',
  24: 'Soundtrack', 26: 'Ambient', 27: 'Trip-Hop', 32: 'Classical', 36: 'Gangsta',
  43: 'Punk', 52: 'Electronic', 79: 'Hard Rock', 80: 'Folk', 88: 'Britpop',
};

/// Resolves numeric ID3v1 references such as "(17)" or "17" to a name.
String? _genre(String? raw) {
  if (raw == null) return null;
  final m = RegExp(r'^\(?(\d{1,3})\)?\s*(.*)$').firstMatch(raw);
  if (m == null) return raw;
  final rest = m.group(2)!.trim();
  if (rest.isNotEmpty) return rest;
  return _id3v1Genres[int.parse(m.group(1)!)] ?? raw;
}

Uint8List _deunsync(Uint8List d) {
  final out = BytesBuilder();
  for (var i = 0; i < d.length; i++) {
    out.addByte(d[i]);
    if (d[i] == 0xFF && i + 1 < d.length && d[i + 1] == 0) i++;
  }
  return out.toBytes();
}

String _decode(int enc, List<int> b) {
  if (b.isEmpty) return '';
  switch (enc) {
    case 1:
    case 2:
      var le = true;
      var s = 0;
      if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
        le = false;
        s = 2;
      } else if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
        s = 2;
      } else if (enc == 2) {
        le = false;
      }
      final units = <int>[];
      for (var i = s; i + 1 < b.length; i += 2) {
        units.add(le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
      }
      return String.fromCharCodes(units);
    case 3:
      return utf8.decode(b, allowMalformed: true);
    default:
      return latin1.decode(b);
  }
}

/// Index of the terminator for [enc] starting at [from], or -1.
int _terminator(Uint8List b, int enc, int from) {
  if (enc == 1 || enc == 2) {
    for (var i = from; i + 1 < b.length; i += 2) {
      if (b[i] == 0 && b[i + 1] == 0) return i;
    }
    return -1;
  }
  for (var i = from; i < b.length; i++) {
    if (b[i] == 0) return i;
  }
  return -1;
}

String? _text(Uint8List f) {
  if (f.isEmpty) return null;
  final t = _decode(f[0], f.sublist(1)).split('\u0000').first.trim();
  return t.isEmpty ? null : t;
}

String? _uslt(Uint8List f) {
  if (f.length < 5) return null;
  final enc = f[0];
  final end = _terminator(f, enc, 4); // skip 3-byte language, then descriptor
  if (end < 0) return null;
  final skip = (enc == 1 || enc == 2) ? 2 : 1;
  final t = _decode(enc, f.sublist(end + skip)).trim();
  return t.isEmpty ? null : t;
}

Uint8List? _apic(Uint8List f) {
  if (f.length < 4) return null;
  final enc = f[0];
  final mimeEnd = _terminator(f, 0, 1);
  if (mimeEnd < 0 || mimeEnd + 2 >= f.length) return null;
  final descStart = mimeEnd + 2; // skip terminator and picture-type byte
  final descEnd = _terminator(f, enc, descStart);
  if (descEnd < 0) return null;
  final skip = (enc == 1 || enc == 2) ? 2 : 1;
  final img = f.sublist(descEnd + skip);
  return img.length > 8 ? Uint8List.fromList(img) : null;
}
