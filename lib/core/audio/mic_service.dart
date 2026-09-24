import 'dart:async';
import 'dart:typed_data';

import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'energy_vad.dart';
import 'pcm_pump.dart';

export 'energy_vad.dart' show VadEvent, VadPhase;

/// Microphone capture -> fixed PCM16 frames + VAD events.
abstract class MicSource {
  Stream<Uint8List> get frames;
  Stream<VadEvent> get vadEvents;
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}

/// Default path: the `record` plugin on the system's chosen input device.
class MicService implements MicSource {
  final int sampleRate;

  /// Created on first use: the plugin opens a stream channel in its
  /// constructor, and picking a microphone must stay cheap.
  AudioRecorder? _recorder;
  AudioRecorder get _rec => _recorder ??= AudioRecorder();

  PcmPump? _pcmPump;
  StreamSubscription<Uint8List>? _captureSub;
  bool _running = false;

  MicService({this.sampleRate = 16000});

  PcmPump get _pump => _pcmPump ??= PcmPump(sampleRate: sampleRate);
  EnergyVad get vad => _pump.vad;

  @override
  Stream<Uint8List> get frames => _pump.frames;
  @override
  Stream<VadEvent> get vadEvents => _pump.vadEvents;
  bool get isRunning => _running;

  Future<bool> hasPermission() => _rec.hasPermission();

  @override
  Future<void> start() async {
    if (_running) return;
    if (!await _rec.hasPermission()) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) throw StateError('microphone permission denied');
    }
    final pump = _pump;
    pump.reset();
    final stream = await _rec.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    _running = true;
    _captureSub = stream.listen((chunk) {
      if (!_running) return;
      pump.feed(chunk);
    }, onError: (Object e) {
      _running = false;
      pump.reportError(e);
    });
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _captureSub?.cancel();
    _captureSub = null;
    await _recorder?.stop();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _pcmPump?.dispose();
    _pcmPump = null;
    await _recorder?.dispose();
    _recorder = null;
  }
}
