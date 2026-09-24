import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

/// Volcengine "bigmodel" bidirectional binary protocol frame codec.
///
/// Frame = [4-byte header][optional 4-byte event][optional 4-byte sequence]
///         [4-byte payload size][payload].
///
/// header bytes:
///  b0: (protocolVersion<<4) | headerSize  = 0x11
///  b1: (messageType<<4) | flags
///  b2: (serialization<<4) | compression
///  b3: reserved 0
///
/// NOTE: values follow the public protocol description; verify against the
/// live endpoint during 联调 before trusting field-by-field.
const _version = 0x1;
const _headerSize = 0x1;

enum VolcMsgType {
  fullClientRequest(0x1),
  audioOnlyRequest(0x2),
  fullServerResponse(0x9),
  audioOnlyResponse(0xb);

  final int value;
  const VolcMsgType(this.value);
}

const _flagPosSeq = 0x1;
const _flagNegSeq = 0x3;
const _flagWithEvent = 0x4;
const _flagNoEvent = 0x8;

/// The sequence field is a 2-bit code: 00 absent, 01 positive, 11 negative
/// (which marks the last packet of a stream).
const _seqMask = 0x3;

const _serialJson = 0x1;
const _serialNone = 0x0;
const _compressGzip = 0x1;

class VolcFrame {
  final VolcMsgType type;
  final int? event;
  final int? sequence;
  final bool lastPacket;
  final Uint8List payload;
  final bool isJson;

  VolcFrame({
    required this.type,
    this.event,
    this.sequence,
    this.lastPacket = false,
    required this.payload,
    this.isJson = false,
  });
}

/// Full-client-request frame: gzip(JSON config) with event=1 (StartExecution).
Uint8List encodeFullClientRequest(Map<String, dynamic> config,
    {int event = 1}) {
  final body = gzip.encode(utf8.encode(json.encode(config)));
  return _build(
    type: VolcMsgType.fullClientRequest,
    flags: _flagWithEvent,
    event: event,
    serialization: _serialJson,
    compression: _compressGzip,
    payload: body,
  );
}

/// Finish/stop request: empty JSON payload with a "finish-session" style
/// event marker (event=2) and last flag.
Uint8List encodeFinishRequest() {
  final body = gzip.encode(utf8.encode(json.encode({})));
  return _build(
    type: VolcMsgType.fullClientRequest,
    flags: _flagWithEvent | _flagNegSeq,
    event: 2,
    serialization: _serialJson,
    compression: _compressGzip,
    payload: body,
    sequence: -1,
  );
}

/// Audio-only frame carrying raw pcm16 chunk.
Uint8List encodeAudioFrame(Uint8List pcm,
    {required int sequence, required bool last}) {
  var flags = _flagNoEvent;
  var seq = sequence;
  if (last) {
    flags |= _flagNegSeq;
    seq = -sequence;
  } else {
    flags |= _flagPosSeq;
  }
  return _build(
    type: VolcMsgType.audioOnlyRequest,
    flags: flags,
    serialization: _serialNone,
    compression: _compressGzip,
    sequence: seq,
    payload: gzip.encode(pcm),
  );
}

Uint8List _build({
  required VolcMsgType type,
  required int flags,
  required int serialization,
  required int compression,
  int? event,
  int? sequence,
  required List<int> payload,
}) {
  final bytes = BytesBuilder();
  bytes.addByte((_version << 4) | _headerSize);
  bytes.addByte((type.value << 4) | flags);
  bytes.addByte((serialization << 4) | compression);
  bytes.addByte(0);
  if ((flags & _flagWithEvent) != 0) {
    bytes.add(_u32(event ?? 1));
  }
  if (sequence != null && (flags & _seqMask) != 0) {
    bytes.add(_u32(sequence & 0xFFFFFFFF));
  }
  bytes.add(_u32(payload.length));
  bytes.add(payload);
  return bytes.toBytes();
}

List<int> _u32(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

/// Decode one server frame. Returns null if the buffer is incomplete or the
/// shape is unknown (then the caller should just wait for more data).
VolcFrame? decodeFrame(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final bd = ByteData.sublistView(bytes);
  final b1 = bytes[1];
  final b2 = bytes[2];
  final typeVal = (b1 >> 4) & 0xf;
  final flags = b1 & 0xf;
  final compression = b2 & 0xf;
  final serialization = (b2 >> 4) & 0xf;
  final type = VolcMsgType.values.firstWhereOrNullType(typeVal);
  var off = 4;
  int? event;
  if ((flags & _flagWithEvent) != 0) {
    if (bytes.length < off + 4) return null;
    event = bd.getUint32(off);
    off += 4;
  }
  int? seq;
  if ((flags & _seqMask) != 0) {
    if (bytes.length < off + 4) return null;
    seq = bd.getInt32(off);
    off += 4;
  }
  if (bytes.length < off + 4) return null;
  final size = bd.getUint32(off);
  off += 4;
  if (bytes.length < off + size) return null;
  var payload = Uint8List.sublistView(bytes, off, off + size);
  if (compression == _compressGzip) {
    try {
      payload = Uint8List.fromList(gzip.decode(payload));
    } catch (_) {
      // leave raw
    }
  }
  return VolcFrame(
    type: type,
    event: event,
    sequence: seq,
    lastPacket: (flags & _seqMask) == _flagNegSeq,
    payload: payload,
    isJson: serialization == _serialJson,
  );
}

extension on List<VolcMsgType> {
  VolcMsgType firstWhereOrNullType(int v) {
    for (final t in this) {
      if (t.value == v) return t;
    }
    return VolcMsgType.fullServerResponse;
  }
}

Map<String, dynamic>? decodeJsonPayload(VolcFrame f) {
  if (!f.isJson) return null;
  try {
    return json.decode(utf8.decode(f.payload)) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}
