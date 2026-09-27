import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aitv/core/config/app_config.dart';
import 'package:aitv/core/providers/llm_provider.dart';
import 'package:aitv/core/state/conversation_engine.dart';
import 'package:aitv/core/state/conversation_log.dart';
import 'package:aitv/core/state/usage_tracker.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// A recognition session that dies without a final result must not wedge the
/// voice loop: the engine has to notice, drop it and start a fresh one.
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

  ConversationEngine buildEngine({LlmProvider? llm}) => ConversationEngine(
        config: config,
        llm: llm ?? _StubLlm(),
        asr: asr,
        tts: tts,
        character: character,
        usage: usage,
        log: ConversationLog(),
        songs: FakeSongPlayer(),
        micFactory: ({required bool preferred}) => mic,
      );

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('aitv_stale_asr');
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

  Future<void> until(bool Function() done, {String? reason}) async {
    for (var i = 0; i < 200; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for ${reason ?? 'condition'}');
  }

  test('a session closed without a final result is replaced', () async {
    await engine.enableMic();
    await until(() => asr.sessions.isNotEmpty);
    expect(asr.sessions, hasLength(1));
    expect(engine.phase, EnginePhase.listening);

    // e.g. silent utterance: finish-task answered with task-finished only,
    // or the WebSocket dropped mid-utterance.
    asr.latest.closeWithoutResult();

    await until(() => asr.sessions.length == 2,
        reason: 'engine must drop the dead session and keep listening');
    expect(engine.phase, EnginePhase.listening);

    // and the loop still hears the next utterance
    mic.speak(1);
    await until(() => asr.latest.frames.isNotEmpty,
        reason: 'frames flow into the fresh session');
  });

  test('a session error is surfaced without wedging the loop', () async {
    await engine.enableMic();
    await until(() => asr.sessions.isNotEmpty);

    asr.latest.failWith(StateError('socket dropped'));

    await until(() => asr.sessions.length == 2,
        reason: 'engine recovers after a stream error');
    expect(engine.phase, EnginePhase.listening);
  });
}

/// Never answers: the stale-session tests only exercise the transport layer.
class _StubLlm implements LlmProvider {
  @override
  Future<void> cancel() async {}

  @override
  Future<String> complete(List<ChatMessage> messages) async =>
      '[MOOD:happy] ok';

  @override
  Stream<String> streamChat(List<ChatMessage> messages) async* {
    yield '[MOOD:happy] ok';
  }
}
