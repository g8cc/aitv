import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aitv/core/audio/mic_service.dart';
import 'package:aitv/core/config/app_config.dart';
import 'package:aitv/core/providers/asr_provider.dart';
import 'package:aitv/core/providers/llm_provider.dart';
import 'package:aitv/core/providers/mock/mock_llm.dart';
import 'package:aitv/core/state/conversation_engine.dart';
import 'package:aitv/core/state/conversation_log.dart';
import 'package:aitv/core/state/usage_tracker.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// The hands-free loop: mic frames + VAD boundaries -> ASR session -> reply.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late AppConfig config;
  late FakeCharacter character;
  late FakeTts tts;
  late FakeMic mic;
  late FakeAsr asr;
  late UsageTracker usage;
  late ConversationEngine engine;

  setUpAll(() {
    config = AppConfig.fromJson(
        json.decode(File('config/app_config.json').readAsStringSync())
            as Map<String, dynamic>);
  });

  ConversationEngine buildEngine(
          {LlmProvider? llm,
          AsrProvider? asrProvider,
          MicSource Function({required bool preferred})? micFactory}) =>
      ConversationEngine(
        config: config,
        llm: llm ?? MockLlm(),
        asr: asrProvider ?? asr,
        tts: tts,
        character: character,
        usage: usage,
        log: ConversationLog(),
        songs: FakeSongPlayer(),
        micFactory:
            micFactory ?? ({required bool preferred}) => mic,
      );

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('aitv_voice');
    SharedPreferences.setMockInitialValues({'daily_limit_min': 30});
    stubPathProvider(docs.path);
    character = FakeCharacter()..completeReady();
    tts = FakeTts();
    mic = FakeMic();
    asr = FakeAsr();
    usage = await UsageTracker.load();
    engine = buildEngine();
    await engine.boot();
  });

  tearDown(() async {
    engine.dispose();
    await tts.dispose();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  /// The pipeline hands work between streams, file writes and timers, so wait
  /// for the state rather than guessing a duration.
  Future<void> until(bool Function() done, {String? reason}) async {
    for (var i = 0; i < 200; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for ${reason ?? 'condition'}');
  }

  List<Map<String, dynamic>> loggedTurns() {
    final f = File('${docs.path}/conversation_log.jsonl');
    if (!f.existsSync()) return const [];
    return f
        .readAsLinesSync()
        .map((l) => json.decode(l) as Map<String, dynamic>)
        .toList();
  }

  Future<void> openMic() async {
    await engine.enableMic();
    await until(() => asr.sessions.isNotEmpty);
  }

  group('voice loop', () {
    test('enabling the mic opens a recognition session', () async {
      await openMic();

      expect(engine.micMode, isTrue);
      expect(engine.phase, EnginePhase.listening);
      expect(asr.sessions, hasLength(1));
      expect(character.actions, contains('tilt'));
    });

    test('an utterance is streamed, ended, recognized and answered', () async {
      await openMic();
      final greeting = tts.spoken.length;

      mic.speak(3);
      await until(() => asr.latest.frames.length == 3);

      mic.pause();
      await until(() => asr.latest.finishRequested);

      asr.latest.heard('hello');
      await until(() => tts.spoken.length > greeting);

      expect(engine.userText, 'hello');
      expect(engine.replyText, contains('Hello'));
      expect(tts.spoken.last, contains('Hello'));
      expect(loggedTurns().last['user'], 'hello');

      await until(() => asr.sessions.length == 2);
      expect(engine.phase, EnginePhase.listening,
          reason: 'ready for the next utterance');
    });

    test('speech captured during the ASR handshake is not clipped', () async {
      final gate = Completer<void>();
      asr.connectGate = gate;
      await engine.enableMic();
      expect(engine.phase, EnginePhase.listening);

      mic.speak(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(asr.sessions, isEmpty, reason: 'still connecting');

      gate.complete();
      await until(() => asr.sessions.isNotEmpty);
      expect(asr.sessions, hasLength(1), reason: 'one session, not two');
      expect(asr.latest.frames, hasLength(2));
    });

    test('a second speech-start does not restart a running session', () async {
      await openMic();

      mic.emitFrame(Uint8List(960));
      mic.emitVad(VadPhase.start);
      mic.emitVad(VadPhase.start);
      await until(() => asr.latest.frames.isNotEmpty);

      expect(asr.sessions, hasLength(1));
      expect(asr.latest.cancelled, isFalse);
      expect(asr.latest.frames, hasLength(1));
    });

    test('the character does not hear itself talk', () async {
      tts.hold = Completer<void>();
      await openMic();
      final sessionsBefore = asr.sessions.length;

      final answering = engine.submitTypedText('hello');
      await until(() => engine.phase == EnginePhase.speaking);

      mic.speak(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(asr.sessions, hasLength(sessionsBefore));
      expect(asr.latest.frames, isEmpty);

      tts.hold!.complete();
      await answering;
      expect(engine.phase, EnginePhase.listening);
    });

    test('voice is ignored outside chat mode', () async {
      await openMic();
      await engine.switchMode(AppMode.story);
      final sessionsBefore = asr.sessions.length;

      mic.speak(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(asr.sessions, hasLength(sessionsBefore));
      expect(asr.latest.frames, isEmpty);
      expect(engine.mode, AppMode.story);
    });

    test('the daily lock closes the mic and unlocking reopens it', () async {
      await openMic();
      expect(mic.startCount, 1);

      usage.limitMinutes = 1;
      for (var i = 0; i < 61; i++) {
        usage.tickSecond();
      }
      await until(() => engine.phase == EnginePhase.locked);
      await until(() => tts.spoken.last.contains('晚安'));
      await until(() => !character.speakingLog.last);
      expect(mic.stopCount, 1);

      usage.limitMinutes = 60;
      await engine.unlock();
      await until(() => asr.sessions.length > 1);
      expect(mic.startCount, 2);
      expect(engine.phase, EnginePhase.listening);
    });

    test('unlocking during the good-night line does not close the mic again',
        () async {
      await openMic();
      tts.hold = Completer<void>();
      usage.limitMinutes = 1;
      for (var i = 0; i < 61; i++) {
        usage.tickSecond();
      }
      await until(() => engine.phase == EnginePhase.speaking);
      expect(tts.spoken.last, contains('晚安'));

      usage.limitMinutes = 60;
      await engine.unlock();
      expect(engine.phase, EnginePhase.listening);
      tts.hold!.complete();

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(engine.phase, EnginePhase.listening,
          reason: 'the finished good-night turn must not reset the mic');
    });
  });

  group('input device choice', () {
    /// Hands the engine one microphone per creation, so a fallback or a
    /// restart can be told apart from the original device.
    ConversationEngine engineWith(List<FakeMic> mics) {
      var next = 0;
      final built =
          buildEngine(micFactory: ({required bool preferred}) => mics[next++]);
      engine.dispose();
      engine = built;
      return built;
    }

    test('a preferred device that cannot record falls back to the default',
        () async {
      final broken = FakeMic()..startError = StateError('device unplugged');
      final fallback = FakeMic();
      final e = engineWith([broken, fallback]);
      await e.boot();
      await e.enableMic();

      expect(broken.disposed, isTrue);
      expect(fallback.startCount, 1);
      expect(e.micMode, isTrue);
      expect(e.phase, EnginePhase.listening);
    });

    test('restartMic moves the running conversation to the new device',
        () async {
      final first = FakeMic();
      final second = FakeMic();
      final e = engineWith([first, second]);
      await e.boot();
      await e.enableMic();
      await until(() => asr.sessions.isNotEmpty);

      await e.restartMic();
      expect(first.disposed, isTrue);
      expect(second.startCount, 1);
      expect(e.micMode, isTrue);

      second.speak(2);
      await until(() => _frameCount(asr) >= 2,
          reason: 'frames from the replacement device are uploaded');
    });

    test('pauseMic frees the microphone and restartMic takes it back',
        () async {
      final first = FakeMic();
      final second = FakeMic();
      final e = engineWith([first, second]);
      await e.boot();
      await e.enableMic();
      await until(() => asr.sessions.isNotEmpty);

      await e.pauseMic();
      expect(first.stopCount, 1);

      await e.restartMic();
      expect(first.disposed, isTrue);
      expect(second.startCount, 1);
      second.speak(1);
      await until(() => _frameCount(asr) >= 1);
    });

    test('restarting without an open microphone does nothing', () async {
      final only = FakeMic();
      final e = engineWith([only]);
      await e.boot();
      await e.pauseMic();
      await e.restartMic();
      expect(only.startCount, 0);
      expect(e.micMode, isFalse);
    });
  });
}

int _frameCount(FakeAsr asr) =>
    asr.sessions.fold<int>(0, (n, s) => n + s.frames.length);
