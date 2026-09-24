import 'dart:async';
import 'dart:typed_data';

import 'package:aitv/core/audio/audio_input.dart';
import 'package:aitv/core/audio/pcm_pump.dart';
import 'package:aitv/core/audio/mic_service.dart';
import 'package:aitv/core/audio/pcm_util.dart';
import 'package:aitv/core/state/mic_settings.dart';
import 'package:aitv/core/state/state_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Loud-enough frame to trip the VAD gate: the noise floor starts at 0.002 and
/// the start threshold is 3x that, so full-scale square wave clears it.
Uint8List _loudFrame([int bytes = 960]) {
  final out = Uint8List(bytes);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < bytes ~/ 2; i++) {
    bd.setInt16(i * 2, (i.isEven ? 9000 : -9000), Endian.little);
  }
  return out;
}

Uint8List _silentFrame([int bytes = 960]) => Uint8List(bytes);

class _FakeInput implements AudioInput {
  final pcm = StreamController<Uint8List>.broadcast();
  final starts = <int, String?>{};
  Object? startError;
  int stopCount = 0;
  List<AudioInputDevice> devices = const [];

  @override
  Future<List<AudioInputDevice>> listDevices() async => devices;

  @override
  Future<AudioInputStart> start({
    int index = -1,
    String? productName,
    int sampleRate = 16000,
  }) async {
    if (startError != null) throw startError!;
    starts[index] = productName;
    return AudioInputStart(
        sampleRate: sampleRate,
        audioSource: 'voice_recognition',
        productName: productName ?? '系统默认');
  }

  @override
  Future<void> stop() async => stopCount++;

  @override
  Stream<Uint8List> listenPcm() => pcm.stream;
}

Future<void> _until(bool Function() done, String reason) async {
  for (var i = 0; i < 200; i++) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('timed out waiting for $reason');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PcmPump', () {
    test('splits arbitrary chunk sizes into fixed 30 ms frames', () async {
      final pump = PcmPump(sampleRate: 16000);
      final frames = <Uint8List>[];
      pump.frames.listen(frames.add);

      // 2500 bytes is not a multiple of 960; the tail must survive.
      pump.feed(Uint8List(2500));
      await Future<void>.delayed(Duration.zero);
      expect(frames, hasLength(2));
      expect(frames.every((f) => f.length == 960), isTrue);

      pump.feed(Uint8List(100));
      await Future<void>.delayed(Duration.zero);
      expect(frames, hasLength(2), reason: '540 leftover bytes are buffered');

      pump.feed(Uint8List(900));
      await Future<void>.delayed(Duration.zero);
      expect(frames, hasLength(3));
      expect(pump.frameBytes, 960);
      await pump.dispose();
    });

    test('frame size follows the sample rate', () {
      expect(PcmPump(sampleRate: 48000).frameBytes, 2880);
      expect(PcmPump(sampleRate: 8000).frameBytes, 480);
    });

    test('drives the VAD and emits start then end', () async {
      final pump = PcmPump(sampleRate: 16000);
      final events = <VadPhase>[];
      pump.vadEvents.listen((e) => events.add(e.phase));
      unawaited(pump.frames.drain());

      for (var i = 0; i < 5; i++) {
        pump.feed(_loudFrame());
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, contains(VadPhase.start));

      for (var i = 0; i < 20; i++) {
        pump.feed(_silentFrame());
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, contains(VadPhase.end));
      expect(PcmUtil.rms(_loudFrame()), greaterThan(0.2));
      await pump.dispose();
    });

    test('reset drops the buffered partial frame', () async {
      final pump = PcmPump(sampleRate: 16000);
      final frames = <Uint8List>[];
      pump.frames.listen(frames.add);
      pump.feed(Uint8List(500));
      pump.reset();
      pump.feed(Uint8List(500));
      await Future<void>.delayed(Duration.zero);
      expect(frames, isEmpty);
      await pump.dispose();
    });

    test('the saved choice decides the microphone', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = MicSettings(prefs);

      expect(buildMicSource(settings, preferred: true), isA<MicService>());

      await settings.setDevice(index: 2, name: 'USB Mic');
      expect(settings.usesNativeDevice, isTrue);
      final chosen = buildMicSource(settings, preferred: true);
      expect(chosen, isA<NativeMic>());
      expect((chosen as NativeMic).inputIndex, 2);
      expect(chosen.inputName, 'USB Mic');
      expect(buildMicSource(settings, preferred: false), isA<MicService>(),
          reason: 'the fallback ignores the saved device');

      await settings.useSystemDefault();
      expect(settings.usesNativeDevice, isFalse);
      expect(buildMicSource(settings, preferred: true), isA<MicService>());
    });

    test('errors reach listeners once reported', () async {
      final pump = PcmPump(sampleRate: 16000);
      Object? seen;
      pump.frames.listen((_) {}, onError: (Object e) => seen = e);
      pump.reportError(StateError('mic died'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, isA<StateError>());
      await pump.dispose();
    });
  });

  group('NativeMic', () {
    test('subscribes before start and forwards frames', () async {
      final input = _FakeInput();
      final mic = NativeMic(input: input, inputIndex: 2, inputName: 'USB Mic');
      final frames = <Uint8List>[];
      mic.frames.listen(frames.add);

      await mic.start();
      expect(input.starts.keys, [2]);
      expect(input.starts[2], 'USB Mic');
      expect(mic.startInfo?.audioSource, 'voice_recognition');

      input.pcm.add(_loudFrame(1920));
      await _until(() => frames.length == 2, 'two frames');
      await mic.dispose();
    });

    test('stop and dispose release the channel and stop feeding', () async {
      final input = _FakeInput();
      final mic = NativeMic(input: input);
      final frames = <Uint8List>[];
      mic.frames.listen(frames.add);
      await mic.start();
      await mic.stop();
      expect(input.stopCount, 1);

      input.pcm.add(_loudFrame(1920));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(frames, isEmpty, reason: 'a stopped mic must not feed the VAD');
      await mic.dispose();
    });

    test('a failed start stops the channel again', () async {
      final input = _FakeInput()..startError = StateError('device busy');
      final mic = NativeMic(input: input);
      await expectLater(mic.start(), throwsA(isA<StateError>()));
      expect(input.stopCount, 1);
      expect(mic.isRunning, isFalse);
      await mic.dispose();
    });

    test('errors from the pcm stream surface on the frame stream', () async {
      final input = _FakeInput();
      final mic = NativeMic(input: input);
      Object? seen;
      mic.frames.listen((_) {}, onError: (Object e) => seen = e);
      await mic.start();
      input.pcm.addError(StateError('device gone'));
      await _until(() => seen != null, 'the error');
      await mic.dispose();
    });
  });

  group('MethodChannelAudioInput', () {
    const channel = MethodChannel('com.kidtv.aitv/audio');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('parses the device list from the platform', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getInputDevices');
        return [
          {
            'index': 0,
            'productName': 'built-in',
            'type': 15,
            'sampleRates': [48000, 16000],
          },
          {'index': 1, 'productName': 'USB Camera'},
        ];
      });

      final devices = await MethodChannelAudioInput().listDevices();
      expect(devices, hasLength(2));
      expect(devices.first.productName, 'built-in');
      expect(devices.first.type, 15);
      expect(devices[1].type, 0);
      expect(devices.first.supportsRate(16000), isTrue);
      expect(devices.first.supportsRate(44100), isFalse);
      expect(devices[1].sampleRates, isEmpty);
      expect(devices[1].supportsRate(16000), isTrue,
          reason: 'an unreported rate list is not a refusal');
      expect(devices.first.toString(), contains('built-in'));
    });

    test('passes the chosen device through to start', () async {
      Map<Object?, Object?>? args;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        args = Map<Object?, Object?>.from(call.arguments as Map);
        return {'sampleRate': 16000, 'audioSource': 'mic', 'productName': 'x'};
      });

      final start = await MethodChannelAudioInput()
          .start(index: 3, productName: 'USB Mic', sampleRate: 16000);
      expect(args?['index'], 3);
      expect(args?['productName'], 'USB Mic');
      expect(start.audioSource, 'mic');
    });
  });
}
