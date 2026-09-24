import 'dart:async';
import 'dart:typed_data';

import 'pcm_util.dart';

/// Adaptive energy VAD. Emits speech-start / speech-end events based on an
/// RMS gate that tracks the ambient noise floor. Tuned for a noisy TV room:
/// requires a few consecutive loud frames to trigger and a hangover of
/// silence before ending an utterance.
class EnergyVad {
  final int frameMs;
  final double startMultiplier;
  final double endMultiplier;
  final int startFrames;
  final int hangoverFrames;
  final int maxUtteranceFrames;

  EnergyVad({
    this.frameMs = 30,
    this.startMultiplier = 3.0,
    this.endMultiplier = 1.8,
    this.startFrames = 3,
    this.hangoverFrames = 15,
    this.maxUtteranceFrames = 400,
  });

  double _noiseFloor = 0.01;
  double _startThresh = 0.03;
  double _endThresh = 0.018;
  bool _speaking = false;
  int _loudRun = 0;
  int _quietRun = 0;
  int _utteranceFrames = 0;

  bool get isSpeaking => _speaking;

  final _events = StreamController<VadEvent>.broadcast();
  Stream<VadEvent> get events => _events.stream;

  /// Feed one frame of 16-bit little-endian PCM.
  void feedFrame(Uint8List bytes) {
    final rms = PcmUtil.rms(bytes);

    if (!_speaking) {
      if (rms > _startThresh) {
        _loudRun++;
        if (_loudRun >= startFrames) {
          _speaking = true;
          _loudRun = 0;
          _quietRun = 0;
          _utteranceFrames = 0;
          _events.add(VadEvent(VadPhase.start, rms));
        }
      } else {
        _loudRun = 0;
      }
      // Noise floor estimate only while idle.
      _noiseFloor = _noiseFloor * 0.95 + rms * 0.05;
      if (_noiseFloor < 0.002) _noiseFloor = 0.002;
      _startThresh = _noiseFloor * startMultiplier;
      _endThresh = _noiseFloor * endMultiplier;
    } else {
      _utteranceFrames++;
      if (rms < _endThresh) {
        _quietRun++;
      } else {
        _quietRun = 0;
      }
      if (_quietRun >= hangoverFrames ||
          _utteranceFrames >= maxUtteranceFrames) {
        _speaking = false;
        _quietRun = 0;
        _events.add(VadEvent(VadPhase.end, rms));
      }
    }
  }

  Future<void> dispose() async {
    await _events.close();
  }
}

enum VadPhase { start, end }

class VadEvent {
  final VadPhase phase;
  final double rms;
  VadEvent(this.phase, this.rms);
}
