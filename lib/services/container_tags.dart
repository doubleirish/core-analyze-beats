import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Tags read from an MP4/M4A (iTunes atoms) or WMA (ASF) file.
class ContainerTags {
  const ContainerTags(
      {this.title,
      this.artist,
      this.album,
      this.genre,
      this.year,
      this.lyrics,
      this.picture,
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
  final String? genre;
  final int? year;
  final String? lyrics;
  final Uint8List? picture;
}

const audioExtensions = ['.mp3', '.m4a', '.wma'];

bool isAudioPath(String path) {
  final p = path.toLowerCase();
  return audioExtensions.any(p.endsWith);
}

bool isMp3Path(String path) => path.toLowerCase().endsWith('.mp3');

/// Reads tags of an .m4a or .wma file; null for other types or on any problem.
Future<ContainerTags?> readContainerTags(String path) async {
  final p = path.toLowerCase();
  if (!p.endsWith('.m4a') && !p.endsWith('.wma')) return null;
  try {
    final raf = await File(path).open();
    try {
      return p.endsWith('.wma') ? await _readAsf(raf) : await _readMp4(raf);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}

const _maxMeta = 48 * 1024 * 1024;

int? _year(String? s) {
  final m = RegExp(r'(\d{4})').firstMatch(s ?? '');
  return m == null ? null : int.parse(m.group(1)!);
}

/// "3/12" or "3" -> (3, 12); zeros count as unknown.
(int?, int?) parseNofM(String? s) {
  final m = RegExp(r'^\s*(\d+)\s*(?:[/of ]+\s*(\d+))?').firstMatch(s ?? '');
  if (m == null) return (null, null);
  int? n(String? v) {
    final i = v == null ? null : int.tryParse(v);
    return i == null || i <= 0 ? null : i;
  }

  return (n(m.group(1)), n(m.group(2)));
}

// ---- MP4 / M4A ----

Future<ContainerTags?> _readMp4(RandomAccessFile raf) async {
  final len = await raf.length();
  var pos = 0;
  while (pos + 8 <= len) {
    await raf.setPosition(pos);
    final h = await raf.read(16);
    if (h.length < 8) break;
    final bd = ByteData.sublistView(h);
    var size = bd.getUint32(0);
    final type = String.fromCharCodes(h.sublist(4, 8));
    var header = 8;
    if (size == 1 && h.length >= 16) {
      size = bd.getUint64(8);
      header = 16;
    } else if (size == 0) {
      size = len - pos;
    }
    if (size < header) break;
    if (type == 'moov') {
      final bodyLen = size - header;
      if (bodyLen > _maxMeta) return null;
      await raf.setPosition(pos + header);
      return _mp4FromMoov(await raf.read(bodyLen));
    }
    pos += size;
  }
  return null;
}

/// Child boxes of [b] between [start, end).
Iterable<(String, int, int)> _boxes(Uint8List b, int start, int end) sync* {
  final bd = ByteData.sublistView(b);
  var p = start;
  while (p + 8 <= end) {
    final size = bd.getUint32(p);
    if (size < 8 || p + size > end) return;
    yield (String.fromCharCodes(b.sublist(p + 4, p + 8)), p + 8, p + size);
    p += size;
  }
}

ContainerTags? _mp4FromMoov(Uint8List moov) {
  for (final (t1, s1, e1) in _boxes(moov, 0, moov.length)) {
    if (t1 != 'udta') continue;
    for (final (t2, s2, e2) in _boxes(moov, s1, e1)) {
      if (t2 != 'meta') continue;
      for (final (t3, s3, e3) in _boxes(moov, s2 + 4, e2)) {
        if (t3 == 'ilst') return _mp4Items(moov, s3, e3);
      }
    }
  }
  return null;
}

ContainerTags _mp4Items(Uint8List b, int start, int end) {
  final text = <String, String>{};
  Uint8List? picture;
  (int?, int?) trkn = (null, null), disk = (null, null);
  (int?, int?) pair(Uint8List p) {
    if (p.length < 6) return (null, null);
    final d = ByteData.sublistView(p);
    final n = d.getUint16(2), t = d.getUint16(4);
    return (n > 0 ? n : null, t > 0 ? t : null);
  }

  for (final (name, s, e) in _boxes(b, start, end)) {
    for (final (t, ds, de) in _boxes(b, s, e)) {
      if (t != 'data' || de - ds < 8) continue;
      final payload = Uint8List.sublistView(b, ds + 8, de);
      if (name == 'covr') {
        picture ??= Uint8List.fromList(payload);
      } else if (name == 'trkn') {
        trkn = pair(payload);
      } else if (name == 'disk') {
        disk = pair(payload);
      } else if (payload.isNotEmpty) {
        text.putIfAbsent(name, () => utf8.decode(payload, allowMalformed: true).trim());
      }
    }
  }
  String? t(String k) => (text[k]?.isEmpty ?? true) ? null : text[k];
  const c = '\u00a9';
  return ContainerTags(
    title: t('${c}nam'),
    artist: t('${c}ART') ?? t('aART'),
    album: t('${c}alb'),
    genre: t('${c}gen'),
    year: _year(t('${c}day')),
    lyrics: t('${c}lyr'),
    picture: picture,
    trackNo: trkn.$1,
    trackTotal: trkn.$2,
    discNo: disk.$1,
    discTotal: disk.$2,
  );
}

// ---- ASF / WMA ----

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

final _asfHeader = '3026b2758e66cf11a6d900aa0062ce6c';
final _asfContent = '3326b2758e66cf11a6d900aa0062ce6c';
final _asfExtended = '40a4d0d2' '07e3d211' '97f000a0c95ea850';

String _utf16(Uint8List b, int start, int len) {
  final end = start + len > b.length ? b.length : start + len;
  final units = <int>[];
  for (var i = start; i + 1 < end; i += 2) {
    final u = b[i] | (b[i + 1] << 8);
    if (u == 0) break;
    units.add(u);
  }
  return String.fromCharCodes(units).trim();
}

Future<ContainerTags?> _readAsf(RandomAccessFile raf) async {
  final head = await raf.read(30);
  if (head.length < 30 || _hex(head.sublist(0, 16)) != _asfHeader) return null;
  final size = ByteData.sublistView(head).getUint64(16, Endian.little);
  if (size < 30 || size > _maxMeta) return null;
  final b = await raf.read(size - 30);
  final bd = ByteData.sublistView(b);

  String? title, artist, album, genre, lyrics;
  int? year, trackNo, trackTotal, discNo, discTotal;
  Uint8List? picture;
  var p = 0;
  while (p + 24 <= b.length) {
    final guid = _hex(b.sublist(p, p + 16));
    final osize = bd.getUint64(p + 16, Endian.little);
    final body = p + 24;
    final end = p + osize;
    if (osize < 24 || end > b.length) break;
    if (guid == _asfContent && body + 10 <= end) {
      final lens = [for (var i = 0; i < 5; i++) bd.getUint16(body + i * 2, Endian.little)];
      var q = body + 10;
      String next(int n) {
        final s = _utf16(b, q, n);
        q += n;
        return s;
      }

      final t = next(lens[0]);
      final a = next(lens[1]);
      next(lens[2]);
      next(lens[3]);
      if (t.isNotEmpty) title = t;
      if (a.isNotEmpty) artist = a;
    } else if (guid == _asfExtended && body + 2 <= end) {
      final count = bd.getUint16(body, Endian.little);
      var q = body + 2;
      for (var i = 0; i < count && q + 2 <= end; i++) {
        final nlen = bd.getUint16(q, Endian.little);
        final name = _utf16(b, q + 2, nlen);
        q += 2 + nlen;
        if (q + 4 > end) break;
        final type = bd.getUint16(q, Endian.little);
        final vlen = bd.getUint16(q + 2, Endian.little);
        final vs = q + 4;
        q = vs + vlen;
        if (q > end) break;
        final str = type == 0
            ? _utf16(b, vs, vlen)
            : type == 3 && vlen >= 4
                ? '${bd.getUint32(vs, Endian.little)}'
                : '';
        switch (name) {
          case 'WM/TrackNumber':
          case 'WM/Track':
            final r = parseNofM(str);
            if (trackNo == null && r.$1 != null) {
              // WM/Track is zero-based
              trackNo = name == 'WM/Track' ? r.$1! + 1 : r.$1;
            }
            trackTotal ??= r.$2;
          case 'WM/PartOfSet':
            final r = parseNofM(str);
            discNo ??= r.$1;
            discTotal ??= r.$2;
          case 'WM/AlbumTitle':
            if (str.isNotEmpty) album = str;
          case 'WM/AlbumArtist':
            if (str.isNotEmpty) artist ??= str;
          case 'WM/Genre':
            if (str.isNotEmpty) genre = str;
          case 'WM/Year':
            year ??= _year(str);
          case 'WM/Lyrics':
            if (str.isNotEmpty) lyrics = str;
          case 'WM/Picture':
            picture ??= _asfPicture(Uint8List.sublistView(b, vs, vs + vlen));
        }
      }
    }
    p = end;
  }
  return ContainerTags(
      title: title,
      artist: artist,
      album: album,
      genre: genre,
      year: year,
      lyrics: lyrics,
      picture: picture,
      trackNo: trackNo,
      trackTotal: trackTotal,
      discNo: discNo,
      discTotal: discTotal);
}

Uint8List? _asfPicture(Uint8List v) {
  if (v.length < 9) return null;
  var p = 5; // type(1) + size(4)
  for (var n = 0; n < 2; n++) {
    // mime and description are null-terminated UTF-16
    while (p + 1 < v.length && !(v[p] == 0 && v[p + 1] == 0)) {
      p += 2;
    }
    p += 2;
  }
  if (p >= v.length) return null;
  return Uint8List.fromList(v.sublist(p));
}
