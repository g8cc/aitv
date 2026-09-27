import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aitv/core/config/app_config.dart';
import 'package:aitv/core/providers/llm_provider.dart';
import 'package:aitv/core/providers/mock/mock_llm.dart';
import 'package:aitv/core/state/conversation_engine.dart';
import 'package:aitv/core/state/conversation_log.dart';
import 'package:aitv/core/state/state_providers.dart';
import 'package:aitv/core/state/usage_tracker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Watches the engine the same way the real chrome (phase dot, mode bar,
/// subtitle, lock overlay) does.
class _Probe extends ConsumerWidget {
  const _Probe();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    return Text(
      '${engine.mode.name}:${engine.phase.name}:${engine.replyText}',
      textDirection: TextDirection.ltr,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late AppConfig config;
  late FakeCharacter character;
  late FakeTts tts;
  late FakeAsr asr;
  late UsageTracker usage;
  late ConversationEngine engine;

  setUpAll(() {
    config = AppConfig.fromJson(
        json.decode(File('config/app_config.json').readAsStringSync())
            as Map<String, dynamic>);
  });

  ConversationEngine buildEngine(LlmProvider llm) => ConversationEngine(
        config: config,
        llm: llm,
        asr: asr,
        tts: tts,
        character: character,
        usage: usage,
        log: ConversationLog(),
        songs: FakeSongPlayer(),
        micFactory: ({required bool preferred}) => FakeMic(),
      );

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('aitv_ui_rebuild');
    SharedPreferences.setMockInitialValues({'daily_limit_min': 30});
    stubPathProvider(docs.path);
    character = FakeCharacter()..completeReady();
    tts = FakeTts();
    asr = FakeAsr();
    usage = await UsageTracker.load();
    engine = buildEngine(MockLlm());
  });

  tearDown(() async {
    // The container disposes the engine through the provider; only clean up
    // the fakes and the temp directory here.
    await tts.dispose();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineProvider.overrideWith((ref) => engine),
        ],
        child: const MaterialApp(
          home: Scaffold(body: _Probe()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('engine changes reach widgets that watch the engine',
      (tester) async {
    await pumpApp(tester);
    expect(find.text('chat:idle:'), findsOneWidget);

    // mode flips synchronously before the async story flow runs.
    unawaited(engine.switchMode(AppMode.story));
    await tester.pump();
    expect(
      find.textContaining('story:'),
      findsOneWidget,
      reason: 'notifyListeners on the engine must rebuild its watchers',
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('reply text updates the screen on every turn', (tester) async {
    await pumpApp(tester);

    await tester.runAsync(() => engine.submitTypedText('hello'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.textContaining('Hello'),
      findsOneWidget,
      reason: 'the spoken reply must be visible without a lucky rebuild',
    );
  });
}
