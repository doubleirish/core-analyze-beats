import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// What the first MPEG frame (and a Xing/Info header, if any) says about an mp3.
class Mp3Probe {
  const Mp3Probe({required this.valid, this.headerSeconds, this.kbps, this.vbr = false});
  final bool valid;

  /// Length implied by the header: frame count (Xing/Info) or size / bitrate (CBR).
  final double? headerSeconds;
  final int? kbps;
  final bool vbr;
}

const _bitrates = {
  // [version1/2][layer] -> kbps table; index 0 and 15 are invalid
  'v1l1': [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
  'v1l2': [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
  'v1l3': [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  'v2l1': [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
  'v2l23': [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
};

bool _sync(Uint8List b, int i) => i + 1 < b.length && b[i] == 0xFF && (b[i + 1] & 0xE0) == 0xE0;

/// Parses the audio frame header of an mp3. [audio] holds the bytes from the end
/// of any ID3v2 tag onward (as many as were read) and [audioBytes] is the full
/// length of the audio part of the file.
Mp3Probe probeMp3(Uint8List audio, int audioBytes) {
  final i = _firstFrame(audio, 0);
  if (i == null) return const Mp3Probe(valid: false);
  final f = _frame(audio, i)!;
  final xing = _xingFrames(audio, i, f);
  if (xing != null) {
    return Mp3Probe(
        valid: true, headerSeconds: xing * f.samples / f.sampleRate, kbps: f.kbps, vbr: true);
  }
  final bytes = audioBytes - i;
  return Mp3Probe(valid: true, headerSeconds: bytes > 0 ? bytes / (f.kbps * 125) : null, kbps: f.kbps);
}

/// First offset at or after [from] holding a frame directly followed by another
/// (two in a row make a false sync very unlikely), or a lone frame at the very end.
int? _firstFrame(Uint8List b, int from) {
  for (var i = from; i + 4 <= b.length; i++) {
    if (!_sync(b, i)) continue;
    final f = _frame(b, i);
    if (f == null) continue;
    final next = i + f.length;
    if (next + 2 <= b.length && !_sync(b, next)) continue;
    return i;
  }
  return null;
}

class _Frame {
  _Frame(this.length, this.kbps, this.sampleRate, this.samples, this.sideInfo);
  final int length;
  final int kbps;
  final int sampleRate;
  final int samples;
  final int sideInfo;
}

_Frame? _frame(Uint8List b, int i) {
  if (i + 4 > b.length) return null;
  final h = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  final ver = (h >> 19) & 3; // 0=2.5 1=reserved 2=v2 3=v1
  final layer = (h >> 17) & 3; // 1=III 2=II 3=I
  final br = (h >> 12) & 15;
  final sr = (h >> 10) & 3;
  final pad = (h >> 9) & 1;
  final mono = ((h >> 6) & 3) == 3;
  if (ver == 1 || layer == 0 || br == 0 || br == 15 || sr == 3) return null;
  final v1 = ver == 3;
  final table = layer == 3
      ? _bitrates[v1 ? 'v1l1' : 'v2l1']!
      : layer == 2
          ? (v1 ? _bitrates['v1l2']! : _bitrates['v2l23']!)
          : (v1 ? _bitrates['v1l3']! : _bitrates['v2l23']!);
  final kbps = table[br];
  final base = const [44100, 48000, 32000][sr];
  final rate = ver == 3 ? base : (ver == 2 ? base ~/ 2 : base ~/ 4);
  final int len;
  final int samples;
  if (layer == 3) {
    len = (12 * kbps * 1000 ~/ rate + pad) * 4;
    samples = 384;
  } else if (layer == 2 || v1) {
    len = 144 * kbps * 1000 ~/ rate + pad;
    samples = 1152;
  } else {
    len = 72 * kbps * 1000 ~/ rate + pad;
    samples = 576;
  }
  final side = v1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
  return _Frame(len, kbps, rate, samples, side);
}

int? _xingFrames(Uint8List b, int i, _Frame f) {
  final o = i + 4 + f.sideInfo;
  if (o + 12 > b.length) return null;
  final tag = String.fromCharCodes(b.sublist(o, o + 4));
  if (tag != 'Xing' && tag != 'Info') return null;
  final flags = b[o + 7];
  if (flags & 1 == 0) return null;
  final n = (b[o + 8] << 24) | (b[o + 9] << 16) | (b[o + 10] << 8) | b[o + 11];
  return n > 0 ? n : null;
}

int _id3v2Size(Uint8List b) =>
    b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33
        ? 10 + ((b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9]) + ((b[5] & 0x10) != 0 ? 10 : 0)
        : 0;

Future<Mp3Probe?> probeMp3File(String path, int size) async {
  if (!path.toLowerCase().endsWith('.mp3')) return null;
  try {
    final raf = await File(path).open();
    try {
      // skip a leading ID3v2 tag (cover art can be large), then read some frames
      final skip = _id3v2Size(await raf.read(10));
      await raf.setPosition(skip);
      final audio = await raf.read(math.min(64 * 1024, math.max(0, size - skip)));
      return probeMp3(audio, size - skip);
    } finally {
      await raf.close();
    }
  } catch (_) {
    return null;
  }
}

// ------------------------------------------------------------- damage check --

/// Result of checking one audio file for damage.
class AudioCheck {
  const AudioCheck.ok({this.seconds}) : damaged = false, reason = null;
  const AudioCheck.damaged(String this.reason, {this.seconds}) : damaged = true;
  final bool damaged;

  /// Why it looks damaged, e.g. "truncated: header says 4:10, audio holds 1:02".
  final String? reason;

  /// Playable length found by the check, when it could tell.
  final double? seconds;

  @override
  String toString() => damaged ? 'damaged: $reason' : 'ok';
}

/// How [AudioCheck]s were made: [quick] reads the file's structure; [deep]
/// decodes all of it (ffmpeg).
enum CheckDepth { quick, deep }

String _clock(double s) => '${s ~/ 60}:${(s % 60).floor().toString().padLeft(2, '0')}';

/// Walks every MPEG frame of an mp3 ([bytes] is the whole file). Damaged when:
/// no audio frames; the Xing/Info frame count promises noticeably more audio
/// than is there (truncated download / copy); or the frame chain breaks
/// mid-file with garbage between frames (corrupted sectors, bad joins).
/// Trailing tags (ID3v1, APE, Lyrics3) and a cut-off last frame are allowed.
AudioCheck checkMp3Bytes(Uint8List bytes) {
  final start0 = _id3v2Size(bytes);
  if (start0 >= bytes.length) return const AudioCheck.damaged('no audio after the tags');
  final first = _firstFrame(bytes, start0);
  if (first == null) return const AudioCheck.damaged('no valid MP3 audio frames found');
  final f0 = _frame(bytes, first)!;
  final promised = _xingFrames(bytes, first, f0);
  var pos = first;
  var frames = 0;
  var seconds = 0.0;
  var gaps = 0;
  var garbage = 0;
  var lastGood = first;
  while (pos + 4 <= bytes.length) {
    final f = _sync(bytes, pos) ? _frame(bytes, pos) : null;
    if (f != null && f.length > 4) {
      if (pos + f.length > bytes.length) break; // cut-off last frame
      frames++;
      seconds += f.samples / f.sampleRate;
      pos += f.length;
      lastGood = pos;
      continue;
    }
    final next = _firstFrame(bytes, pos + 1);
    if (next == null) break; // the rest is trailing tags or junk
    gaps++;
    garbage += next - pos;
    pos = next;
  }
  final tail = bytes.length - lastGood;
  if (frames < 2) return const AudioCheck.damaged('no valid MP3 audio frames found');
  if (promised != null) {
    final expected = promised * f0.samples / f0.sampleRate;
    if (expected - seconds > math.max(5, expected * 0.03)) {
      return AudioCheck.damaged(
          'truncated: header says ${_clock(expected)}, audio holds ${_clock(seconds)}',
          seconds: seconds);
    }
  }
  final audioBytes = math.max(1, lastGood - first);
  if (gaps > 3 || garbage > math.max(8 * 1024, audioBytes ~/ 200)) {
    return AudioCheck.damaged(
        '$gaps damaged section${gaps == 1 ? '' : 's'} (${(garbage / 1024).ceil()} KB unreadable)',
        seconds: seconds);
  }
  // A large unreadable tail that is not a known tag also means damage.
  if (tail > 64 * 1024 && !_looksLikeTrailingTags(bytes, lastGood)) {
    return AudioCheck.damaged('${(tail / 1024).round()} KB of unreadable data at the end',
        seconds: seconds);
  }
  return AudioCheck.ok(seconds: seconds);
}

bool _looksLikeTrailingTags(Uint8List b, int from) {
  String at(int i, int n) => i >= 0 && i + n <= b.length ? String.fromCharCodes(b.sublist(i, i + n)) : '';
  for (var i = from; i < math.min(b.length, from + 256); i++) {
    final s = at(i, 8);
    if (s.startsWith('TAG') || s == 'APETAGEX' || s.startsWith('LYRICSBE') || s.startsWith('ID3')) {
      return true;
    }
  }
  return false;
}

/// Container sanity for non-MP3 files: the right signature, and (WAV, MP4)
/// declared sizes that fit in the file. [size] is the real file size.
AudioCheck checkContainerHead(String path, Uint8List head, int size, {List<(int, int)>? mp4Boxes}) {
  final ext = path.toLowerCase().split('.').last;
  String at(int i, int n) => i + n <= head.length ? String.fromCharCodes(head.sublist(i, i + n)) : '';
  switch (ext) {
    case 'flac':
      final skip = _id3v2Size(head);
      return at(skip, 4) == 'fLaC'
          ? const AudioCheck.ok()
          : const AudioCheck.damaged('not a valid FLAC file (no fLaC signature)');
    case 'ogg' || 'opus':
      return at(0, 4) == 'OggS'
          ? const AudioCheck.ok()
          : const AudioCheck.damaged('not a valid Ogg file (no OggS signature)');
    case 'wav':
      if (at(0, 4) != 'RIFF' || at(8, 4) != 'WAVE') {
        return const AudioCheck.damaged('not a valid WAV file (no RIFF/WAVE header)');
      }
      final declared = (head[4] | (head[5] << 8) | (head[6] << 16) | (head[7] << 24)) + 8;
      if (declared > size + 1 && declared - size > math.max(4096, declared ~/ 100)) {
        return AudioCheck.damaged(
            'truncated: header says ${(declared / 1024).round()} KB, file has ${(size / 1024).round()} KB');
      }
      return const AudioCheck.ok();
    case 'm4a' || 'mp4':
      if (at(4, 4) != 'ftyp') return const AudioCheck.damaged('not a valid MP4/M4A file (no ftyp box)');
      final boxes = mp4Boxes ?? const [];
      if (boxes.isNotEmpty && boxes.last.$1 + boxes.last.$2 > size) {
        return AudioCheck.damaged(
            'truncated: last box needs ${((boxes.last.$1 + boxes.last.$2 - size) / 1024).ceil()} KB more');
      }
      return const AudioCheck.ok();
    default:
      return const AudioCheck.ok();
  }
}

/// Reads at most this much of an mp3 for the frame walk (longer files are
/// checked over their first part plus their end).
const maxQuickCheckBytes = 96 * 1024 * 1024;

/// Quick damage check of one file: a full frame walk for MP3s, container
/// sanity otherwise. Empty files are damaged; files that can't be opened
/// throw (a missing file is not "damaged").
Future<AudioCheck> quickCheckFile(String path) async {
  final file = File(path);
  final size = await file.length();
  if (size == 0) return const AudioCheck.damaged('file is empty');
  if (path.toLowerCase().endsWith('.mp3')) {
    if (size <= maxQuickCheckBytes) return checkMp3Bytes(await file.readAsBytes());
    final raf = await file.open();
    try {
      return checkMp3Bytes(await raf.read(maxQuickCheckBytes));
    } finally {
      await raf.close();
    }
  }
  final raf = await file.open();
  try {
    final head = await raf.read(64);
    List<(int, int)>? boxes;
    if (head.length >= 8 && String.fromCharCodes(head.sublist(4, 8)) == 'ftyp') {
      boxes = [];
      var pos = 0;
      while (pos + 8 <= size && boxes.length < 64) {
        await raf.setPosition(pos);
        final h = await raf.read(16);
        if (h.length < 8) break;
        var len = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
        if (len == 1 && h.length >= 16) {
          len = 0;
          for (var k = 8; k < 16; k++) {
            len = len * 256 + h[k];
          }
        }
        if (len == 0) len = size - pos; // box runs to the end
        if (len < 8) {
          boxes.add((pos, size + 1)); // nonsense length: treat as damaged
          break;
        }
        boxes.add((pos, len));
        pos += len;
      }
    }
    return checkContainerHead(path, head, size, mp4Boxes: boxes);
  } finally {
    await raf.close();
  }
}

/// Runs a process; injectable so the deep check can be tested without ffmpeg.
typedef ProcessRunner = Future<ProcessResult> Function(String exe, List<String> args);

Future<ProcessResult> _run(String exe, List<String> args) => Process.run(exe, args);

/// Deep damage check: decodes the file's audio with [ffmpeg]. A handful of
/// isolated glitches (one bad frame is a click at most, and very common in
/// older rips) is tolerated; more than [maxErrors] decoder errors, or a file
/// ffmpeg can't open, is damaged. Cover-art and container warnings are ignored.
Future<AudioCheck> deepCheckFile(String path, String ffmpeg,
    {ProcessRunner run = _run, int maxErrors = 3}) async {
  final r = await run(
      ffmpeg, ['-v', 'error', '-nostdin', '-i', path, '-map', '0:a:0', '-f', 'null', '-']);
  final errors = '${r.stderr}'
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !_ignorableFfmpegLine(l))
      .toList();
  if (r.exitCode != 0 || errors.length > maxErrors) {
    final first = errors.isEmpty ? 'ffmpeg exit code ${r.exitCode}' : errors.first;
    final more = errors.length > 1 ? ' (+${errors.length - 1} more)' : '';
    final reason = 'decode error: ${first.length > 160 ? '${first.substring(0, 160)}…' : first}$more';
    return AudioCheck.damaged(reason);
  }
  return const AudioCheck.ok();
}

/// ffmpeg error lines that don't mean the audio is damaged: artwork streams,
/// RIFF-wrapped MP3 quirks, and the "Error submitting packet" echo that
/// follows every real decoder error (so it isn't counted twice).
bool _ignorableFfmpegLine(String l) =>
    l.contains('[mjpeg') ||
    l.contains('[png') ||
    l.contains('RIFF header') ||
    l.contains('Error submitting packet') ||
    l.contains('Error while decoding stream') && l.contains('Invalid data');
