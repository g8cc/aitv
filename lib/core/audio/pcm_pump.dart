import 'dart:async';
import 'dart:typed_data';

import 'energy_vad.dart';

/// Cuts an arbitrary-length PCM16 byte stream into fixed 30 ms frames, feeds
/// the [EnergyVad], and republishes the frames for ASR upload.
///
/// Both mic sources (the `record` plugin and the native input-device channel)
/// deliver chunks of unpredictable size, so the framing lives here and the
/// sources stay thin.
class PcmPump {
  final int sampleRate;
  final EnergyVad vad;
  final int frameBytes;

  final _frames = StreamController<Uint8List>.broadcast();
  final _carry = BytesBuilder(copy: true);
  bool _open = true;

  PcmPump({required this.sampleRate, EnergyVad? vad})
      : vad = vad ?? EnergyVad(frameMs: 30),
        frameBytes = (sampleRate * 30 ~/ 1000) * 2;

  Stream<Uint8List> get frames => _frames.stream;
  Stream<VadEvent> get vadEvents => vad.events;

  void feed(Uint8List chunk) {
    if (!_open || chunk.isEmpty) return;
    _carry.add(chunk);
    final bytes = _carry.takeBytes();
    final usable = bytes.length - (bytes.length % frameBytes);
    if (usable < bytes.length) {
      _carry.add(Uint8List.sublistView(bytes, usable));
    }
    for (var off = 0; off + frameBytes <= usable; off += frameBytes) {
      final frame = Uint8List.sublistView(bytes, off, off + frameBytes);
      vad.feedFrame(frame);
      _frames.add(frame);
    }
  }

  /// Drops the buffered partial frame, e.g. after a device change.
  void reset() => _carry.clear();

  void reportError(Object error) {
    if (_open) _frames.addError(error);
  }

  Future<void> dispose() async {
    _open = false;
    reset();
    await vad.dispose();
    await _frames.close();
  }
}
