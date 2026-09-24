import 'dart:async';

import 'package:aitv/character/character_controller.dart';
import 'package:aitv/core/audio/mic_service.dart';
import 'package:aitv/core/audio/song_player.dart';
import 'package:aitv/core/providers/asr_provider.dart';
import 'package:aitv/core/providers/llm_provider.dart';
import 'package:aitv/core/providers/tts_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;

/// Fakes for the device-facing layers (WebView, microphone, cloud speech,
/// audio plugin) so the conversation loop can be tested end to end.

/// Records everything the conversation loop asks the on-screen character to
/// do.
class FakeCharacter implements CharacterDriver {
  final _ready = Completer<void>();
  final actions = <String>[];
  final speakingLog = <bool>[];
  final lips = <double>[];

  void completeReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  @override
  Future<void> get ready => _ready.future;

  @override
  void setLip(double value) => lips.add(value);

  @override
  void setSpeaking(bool on) => speakingLog.add(on);

  @override
  void playAction(String name) => actions.add(name);

  @override
  void mood(String mood) => actions.add('mood:$mood');
}

/// Stands in for cloud/system speech: remembers the text and replays a short
/// amplitude envelope like a real utterance would.
class FakeTts implements TtsProvider {
  final _amp = StreamController<double>.broadcast();
  final spoken = <String>[];

  /// When set, [speak] blocks until it completes, holding the engine in the
  /// speaking phase so a fake utterance can be pushed meanwhile.
  Completer<void>? hold;

  @override
  Stream<double> get amplitudes => _amp.stream;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    for (final v in [0.4, 0.9, 0.5]) {
      _amp.add(v);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    _amp.add(0);
    await hold?.future;
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async => _amp.close();
}

/// The nursery-rhyme player without the audio plugin. [failNext] emulates a
/// missing or broken asset file.
class FakeSongPlayer implements SongPlayer {
  final played = <String>[];
  final _onFinished = <void Function()>[];
  bool failNext = false;

  @override
  Future<void> play(String asset, {required void Function() onFinished}) async {
    if (failNext) throw StateError('cannot load $asset');
    played.add(asset);
    _onFinished.add(onFinished);
  }

  /// Pretend the current track just reached its end.
  void finishCurrent() => _onFinished.last();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// A microphone the test drives by hand: [speak] pushes PCM frames, [pause]
/// marks the end of an utterance.
class FakeMic implements MicSource {
  final _frames = StreamController<Uint8List>.broadcast();
  final _vad = StreamController<VadEvent>.broadcast();
  int startCount = 0;
  int stopCount = 0;
  bool disposed = false;
  Object? startError;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Stream<VadEvent> get vadEvents => _vad.stream;

  void speak(int frameCount) {
    emitVad(VadPhase.start);
    for (var i = 0; i < frameCount; i++) {
      _frames.add(Uint8List(960));
    }
  }

  void emitVad(VadPhase phase, [double rms = 0.1]) =>
      _vad.add(VadEvent(phase, rms));

  void emitFrame(Uint8List frame) => _frames.add(frame);

  void pause() => emitVad(VadPhase.end);

  @override
  Future<void> start() async {
    if (startError != null) throw startError!;
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _frames.close();
    await _vad.close();
  }
}

/// Streaming recognition that keeps every session so the test can inspect the
/// frames it received and decide what was "heard".
class FakeAsr implements AsrProvider {
  final sessions = <FakeAsrSession>[];

  /// When set, [startSession] waits for this, emulating a slow WebSocket
  /// handshake.
  Completer<void>? connectGate;

  @override
  Future<AsrSession> startSession() async {
    final gate = connectGate;
    if (gate != null) await gate.future;
    final s = FakeAsrSession();
    sessions.add(s);
    return s;
  }

  FakeAsrSession get latest => sessions.last;
}

class FakeAsrSession implements AsrSession {
  final _out = StreamController<AsrResult>();
  final frames = <Uint8List>[];
  bool finishRequested = false;
  bool cancelled = false;

  @override
  Stream<AsrResult> get results => _out.stream;

  @override
  void addFrame(Uint8List pcm16) => frames.add(pcm16);

  /// The last transcript, delivered after speech-end was signalled.
  void heard(String text) {
    if (_out.isClosed) return;
    _out.add(AsrResult(text, isFinal: true));
    _out.close();
  }

  @override
  Future<void> finish() async {
    finishRequested = true;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!_out.isClosed) await _out.close();
  }
}

/// Captures the prompt the engine sends, and answers with whatever the test
/// puts in [answer].
class SpyLlm implements LlmProvider {
  final prompts = <List<ChatMessage>>[];
  String answer = '[MOOD:cheer] Nice!';

  @override
  Future<String> complete(List<ChatMessage> messages) async {
    prompts.add(List.of(messages));
    return answer;
  }

  @override
  Stream<String> streamChat(List<ChatMessage> messages) async* {
    prompts.add(List.of(messages));
    yield answer;
  }
}

/// Points path_provider at [path] for the duration of the test.
void stubPathProvider(String path) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => path);
}
