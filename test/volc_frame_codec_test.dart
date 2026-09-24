import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:aitv/core/providers/volc/volc_frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List serverFrame({
  required int msgType,
  required int flags,
  int? event,
  int? sequence,
  required List<int> payload,
}) {
  final out = BytesBuilder();
  out.addByte(0x11);
  out.addByte((msgType << 4) | flags);
  out.addByte((0x1 << 4) | 0x1); // json + gzip
  out.addByte(0);
  if ((flags & 0x4) != 0) {
    out.add(_u32(event ?? 0));
  }
  if ((flags & 0x3) != 0) {
    out.add(_u32((sequence ?? 0) & 0xFFFFFFFF));
  }
  out.add(_u32(payload.length));
  out.add(payload);
  return out.toBytes();
}

List<int> _u32(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

void main() {
  group('volc frame codec', () {
    test('config request round-trips to a json payload', () {
      final cfg = {'model': 'bigmodel', 'sample_rate': 16000};
      final f = decodeFrame(encodeFullClientRequest(cfg))!;
      expect(f.type, VolcMsgType.fullClientRequest);
      expect(f.event, 1);
      expect(f.isJson, isTrue);
      expect(f.lastPacket, isFalse);
      expect(decodeJsonPayload(f), cfg);
    });

    test('audio frame keeps its sequence number', () {
      final pcm = Uint8List.fromList(List.generate(960, (i) => i % 251));
      final f = decodeFrame(encodeAudioFrame(pcm, sequence: 7, last: false))!;
      expect(f.type, VolcMsgType.audioOnlyRequest);
      expect(f.sequence, 7);
      expect(f.lastPacket, isFalse);
      expect(f.isJson, isFalse);
      expect(f.payload, pcm);
    });

    test('last audio frame is marked with a negative sequence', () {
      final f =
          decodeFrame(encodeAudioFrame(Uint8List(0), sequence: 9, last: true))!;
      expect(f.lastPacket, isTrue);
      expect(f.sequence, -9);
    });

    test('finish request carries an event and the last-packet flag', () {
      final f = decodeFrame(encodeFinishRequest())!;
      expect(f.type, VolcMsgType.fullClientRequest);
      expect(f.event, 2);
      expect(f.lastPacket, isTrue);
      expect(decodeJsonPayload(f), isEmpty);
    });

    test('decodes a server response frame', () {
      final body = gzip.encode(utf8.encode(json.encode({
        'result': {'text': 'hello'}
      })));
      final f = decodeFrame(
          serverFrame(msgType: 0x9, flags: 0x4, event: 200, payload: body))!;
      expect(f.type, VolcMsgType.fullServerResponse);
      expect(f.event, 200);
      expect(f.sequence, isNull);
      expect(decodeJsonPayload(f), {
        'result': {'text': 'hello'}
      });
    });

    test('incomplete buffers decode to null', () {
      final full = encodeFullClientRequest({'a': 1});
      for (final cut in [1, 4, 8, 12, full.length - 1]) {
        expect(decodeFrame(Uint8List.sublistView(full, 0, cut)), isNull,
            reason: 'cut at $cut');
      }
    });
  });
}
