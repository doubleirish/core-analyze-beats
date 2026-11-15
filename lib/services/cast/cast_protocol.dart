import 'dart:convert';
import 'dart:typed_data';

/// One Cast v2 message with a string (JSON) payload.
class CastMessage {
  const CastMessage({
    required this.sourceId,
    required this.destinationId,
    required this.namespace,
    required this.payload,
  });

  final String sourceId, destinationId, namespace, payload;
}

void _varint(BytesBuilder b, int v) {
  while (v > 0x7f) {
    b.addByte((v & 0x7f) | 0x80);
    v >>= 7;
  }
  b.addByte(v);
}

void _string(BytesBuilder b, int field, String s) {
  final bytes = utf8.encode(s);
  b.addByte((field << 3) | 2);
  _varint(b, bytes.length);
  b.add(bytes);
}

/// Encodes [m] as a protobuf CastMessage, prefixed with its 4-byte big-endian length.
Uint8List encodeCastFrame(CastMessage m) {
  final body = BytesBuilder();
  body.addByte(0x08); // protocol_version = CASTV2_1_0
  body.addByte(0);
  _string(body, 2, m.sourceId);
  _string(body, 3, m.destinationId);
  _string(body, 4, m.namespace);
  body.addByte(0x28); // payload_type = STRING
  body.addByte(0);
  _string(body, 6, m.payload);
  final bytes = body.toBytes();
  final out = BytesBuilder();
  out.add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
  out.add(bytes);
  return out.toBytes();
}

/// Decodes a protobuf CastMessage body (without the length prefix). Returns
/// null for messages without a string payload.
CastMessage? decodeCastMessage(Uint8List b) {
  var i = 0;
  int readVarint() {
    var v = 0, shift = 0;
    while (i < b.length) {
      final x = b[i++];
      v |= (x & 0x7f) << shift;
      if (x & 0x80 == 0) break;
      shift += 7;
    }
    return v;
  }

  String src = '', dst = '', ns = '';
  String? payload;
  while (i < b.length) {
    final tag = readVarint();
    final field = tag >> 3;
    switch (tag & 7) {
      case 0:
        readVarint();
      case 2:
        final len = readVarint();
        if (i + len > b.length) return null;
        final data = Uint8List.sublistView(b, i, i + len);
        i += len;
        switch (field) {
          case 2:
            src = utf8.decode(data);
          case 3:
            dst = utf8.decode(data);
          case 4:
            ns = utf8.decode(data);
          case 6:
            payload = utf8.decode(data);
        }
      case 1:
        i += 8;
      case 5:
        i += 4;
      default:
        return null;
    }
  }
  if (payload == null) return null;
  return CastMessage(sourceId: src, destinationId: dst, namespace: ns, payload: payload);
}

/// Splits a byte stream into length-prefixed Cast messages.
class CastFrameReader {
  Uint8List _rest = Uint8List(0);

  List<CastMessage> add(List<int> chunk) {
    final data = Uint8List(_rest.length + chunk.length)
      ..setAll(0, _rest)
      ..setAll(_rest.length, chunk);
    final out = <CastMessage>[];
    var at = 0;
    while (data.length - at >= 4) {
      final len = ByteData.sublistView(data, at, at + 4).getUint32(0);
      if (data.length - at - 4 < len) break;
      final m = decodeCastMessage(Uint8List.sublistView(data, at + 4, at + 4 + len));
      if (m != null) out.add(m);
      at += 4 + len;
    }
    _rest = Uint8List.fromList(Uint8List.sublistView(data, at));
    return out;
  }
}
