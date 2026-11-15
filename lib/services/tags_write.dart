import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'container_tags.dart' show isMp3Path;

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

void _putSyncsafe(BytesBuilder out, int n) => out.add([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F]);

void _putBe32(BytesBuilder out, int n) => out.add([(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF]);

Uint8List _textFrame(String id, String text, int ver) {
  final body = BytesBuilder();
  if (ver == 4) {
    body.addByte(3);
    body.add(utf8.encode(text));
  } else {
    body.addByte(1);
    body.add([0xFF, 0xFE]);
    for (final u in text.codeUnits) {
      body.add([u & 0xFF, u >> 8]);
    }
  }
  final out = BytesBuilder()..add(ascii.encode(id));
  ver == 4 ? _putSyncsafe(out, body.length) : _putBe32(out, body.length);
  out.add([0, 0]);
  out.add(body.toBytes());
  return out.toBytes();
}

/// Builds an ID3v2.3/2.4 tag that replaces the title (TIT2), artist (TPE1) and
/// album (TALB) given and keeps every other frame byte for byte.
///
/// [oldTag] is the complete existing tag (10-byte header included), or null for
/// a file without one. Returns null when the existing tag can't be edited
/// safely (ID3v2.2, whole-tag unsynchronisation, or damaged frames).
Uint8List? buildId3Tag(Uint8List? oldTag, {String? title, String? artist, String? album, int padding = 512}) {
  final replace = <String, String>{'TIT2': ?title, 'TPE1': ?artist, 'TALB': ?album};
  var ver = 3;
  var oldSize = 0;
  final frames = BytesBuilder();
  if (oldTag != null) {
    if (oldTag.length < 10) return null;
    ver = oldTag[3];
    final flags = oldTag[5];
    if ((ver != 3 && ver != 4) || flags & 0x80 != 0) return null;
    oldSize = _syncsafe(oldTag, 6);
    final end = 10 + oldSize;
    if (end > oldTag.length) return null;
    var pos = 10;
    if (flags & 0x40 != 0) {
      if (pos + 4 > end) return null;
      pos += ver == 4
          ? _syncsafe(oldTag, pos)
          : ((oldTag[pos] << 24) | (oldTag[pos + 1] << 16) | (oldTag[pos + 2] << 8) | oldTag[pos + 3]) + 4;
    }
    while (pos + 10 <= end) {
      if (oldTag[pos] == 0) break;
      final id = String.fromCharCodes(oldTag.sublist(pos, pos + 4));
      final sz = ver == 4
          ? _syncsafe(oldTag, pos + 4)
          : (oldTag[pos + 4] << 24) | (oldTag[pos + 5] << 16) | (oldTag[pos + 6] << 8) | oldTag[pos + 7];
      if (sz < 0 || pos + 10 + sz > end) return null;
      if (!replace.containsKey(id)) frames.add(oldTag.sublist(pos, pos + 10 + sz));
      pos += 10 + sz;
    }
  }
  for (final e in replace.entries) {
    frames.add(_textFrame(e.key, e.value, ver));
  }
  final used = frames.length;
  final pad = oldSize > used ? oldSize - used : padding;
  final out = BytesBuilder()..add([0x49, 0x44, 0x33, ver, 0, 0]);
  _putSyncsafe(out, used + pad);
  out.add(frames.toBytes());
  out.add(Uint8List(pad));
  return out.toBytes();
}

/// Writes title/artist/album into an MP3's ID3v2 tag, leaving the other frames
/// (cover art, lyrics...) and the audio untouched. The file is rewritten through
/// a temporary file and a rename. Returns false when the file isn't an MP3 or
/// its tag can't be edited safely; throws on I/O errors.
Future<bool> writeMp3Tags(String path, {String? title, String? artist, String? album}) async {
  if (!isMp3Path(path)) return false;
  final file = File(path);
  Uint8List? old;
  var oldTotal = 0;
  final raf = await file.open();
  try {
    final head = await raf.read(10);
    if (head.length == 10 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
      final size = _syncsafe(head, 6);
      if (size > 64 * 1024 * 1024) return false;
      final body = await raf.read(size);
      if (body.length < size) return false;
      old = Uint8List.fromList([...head, ...body]);
      oldTotal = 10 + size;
    }
  } finally {
    await raf.close();
  }
  final tag = buildId3Tag(old, title: title, artist: artist, album: album);
  if (tag == null) return false;
  final tmp = File('$path.relabel.tmp');
  try {
    final sink = tmp.openWrite();
    sink.add(tag);
    await sink.addStream(file.openRead(oldTotal));
    await sink.flush();
    await sink.close();
    await tmp.rename(path);
  } catch (_) {
    if (await tmp.exists()) await tmp.delete();
    rethrow;
  }
  return true;
}
