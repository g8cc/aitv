import 'dart:async';

import 'package:flutter/services.dart';

import 'mic_service.dart';
import 'pcm_pump.dart';

/// A recording input device reported by Android.
class AudioInputDevice {
  final int index;
  final String productName;
  /// Android audio device type code, e.g. 15 for a USB microphone.
  final int type;
  final List<int> sampleRates;

  const AudioInputDevice({
    required this.index,
    required this.productName,
    required this.type,
    required this.sampleRates,
  });

  bool supportsRate(int rate) =>
      sampleRates.isEmpty || sampleRates.contains(rate);

  factory AudioInputDevice.fromMap(Map<Object?, Object?> m) => AudioInputDevice(
        index: (m['index'] as int?) ?? -1,
        productName: (m['productName'] as String?) ?? '未知设备',
        type: (m['type'] as int?) ?? 0,
        sampleRates: ((m['sampleRates'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList(),
      );

  @override
  String toString() => '#$index $productName';
}

/// The result of starting a capture: which audio source actually worked.
class AudioInputStart {
  final int sampleRate;
  final String audioSource;
  final String productName;

  const AudioInputStart({
    required this.sampleRate,
    required this.audioSource,
    required this.productName,
  });

  factory AudioInputStart.fromMap(Map<Object?, Object?> m) => AudioInputStart(
        sampleRate: (m['sampleRate'] as int?) ?? 16000,
        audioSource: (m['audioSource'] as String?) ?? '',
        productName: (m['productName'] as String?) ?? '',
      );
}

/// Raw PCM capture with explicit device selection.  Seam for tests and for
/// non-Android hosts, where the native channel does not exist.
abstract class AudioInput {
  Future<List<AudioInputDevice>> listDevices();

  /// [index] < 0 keeps the system default device.
  Future<AudioInputStart> start({
    int index = -1,
    String? productName,
    int sampleRate = 16000,
  });

  Future<void> stop();

  Stream<Uint8List> listenPcm();
}

class MethodChannelAudioInput implements AudioInput {
  static const _method = MethodChannel('com.kidtv.aitv/audio');
  static const _events = EventChannel('com.kidtv.aitv/audio/pcm');

  @override
  Future<List<AudioInputDevice>> listDevices() async {
    final raw = await _method.invokeMethod<List<Object?>>('getInputDevices');
    return (raw ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map(AudioInputDevice.fromMap)
        .toList();
  }

  @override
  Future<AudioInputStart> start({
    int index = -1,
    String? productName,
    int sampleRate = 16000,
  }) async {
    final raw = await _method.invokeMethod<Map<Object?, Object?>>('start', {
      'index': index,
      'productName': productName,
      'sampleRate': sampleRate,
    });
    if (raw == null) throw StateError('native audio start returned nothing');
    return AudioInputStart.fromMap(raw);
  }

  @override
  Future<void> stop() async => _method.invokeMethod<bool>('stop');

  @override
  Stream<Uint8List> listenPcm() =>
      _events.receiveBroadcastStream().map((e) => e as Uint8List);
}

/// [MicSource] backed by [AudioInput]: works on TVs whose default input device
/// is silent but which expose a usable USB or remote microphone.
class NativeMic implements MicSource {
  final AudioInput input;
  final int inputIndex;
  final String? inputName;
  final int sampleRate;

  PcmPump? _pcmPump;
  StreamSubscription<Uint8List>? _sub;
  bool _running = false;
  AudioInputStart? _startInfo;

  NativeMic({
    AudioInput? input,
    this.inputIndex = -1,
    this.inputName,
    this.sampleRate = 16000,
  }) : input = input ?? MethodChannelAudioInput();

  PcmPump get _pump => _pcmPump ??= PcmPump(sampleRate: sampleRate);

  @override
  Stream<Uint8List> get frames => _pump.frames;
  @override
  Stream<VadEvent> get vadEvents => _pump.vadEvents;
  bool get isRunning => _running;

  /// What the platform actually opened, e.g. `voice_recognition`.
  AudioInputStart? get startInfo => _startInfo;

  @override
  Future<void> start() async {
    if (_running) return;
    final pump = _pump..reset();
    // The sink has to exist before the native side starts pushing frames.
    _sub = input.listenPcm().listen(
          (chunk) {
            if (_running) pump.feed(chunk);
          },
          onError: (Object e) => pump.reportError(e),
        );
    try {
      _startInfo = await input.start(
        index: inputIndex,
        productName: inputName,
        sampleRate: sampleRate,
      );
      _running = true;
    } catch (e) {
      await stop();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await input.stop();
    } catch (_) {
      // A dead channel has nothing left to stop.
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _pcmPump?.dispose();
    _pcmPump = null;
  }
}
