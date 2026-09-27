import 'dart:convert';
import 'dart:io';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late AppConfig config;
  late FakeCharacter character;
  late FakeTts tts;
  late FakeSongPlayer songs;
  late UsageTracker usage;
  late ConversationEngine engine;

  setUpAll(() {
    config = AppConfig.fromJson(
        json.decode(File('config/app_config.json').readAsStringSync())
            as Map<String, dynamic>);
  });

  /// Builds the engine around the fakes, e.g. with a [SpyLlm].
  ConversationEngine buildEngine(LlmProvider llm) => ConversationEngine(
        config: config,
        llm: llm,
        asr: MockAsrProvider(),
        tts: tts,
        character: character,
        usage: usage,
        log: ConversationLog(),
        songs: songs,
      );

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('aitv_e2e');
    SharedPreferences.setMockInitialValues({'daily_limit_min': 30});
    stubPathProvider(docs.path);
    character = FakeCharacter()..completeReady();
    tts = FakeTts();
    songs = FakeSongPlayer();
    usage = await UsageTracker.load();
    engine = buildEngine(MockLlm());
  });

  tearDown(() async {
    engine.dispose();
    await tts.dispose();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  List<Map<String, dynamic>> loggedTurns() {
    final f = File('${docs.path}/conversation_log.jsonl');
    if (!f.existsSync()) return const [];
    return f
        .readAsLinesSync()
        .map((l) => json.decode(l) as Map<String, dynamic>)
        .toList();
  }

  group('mock chat', () {
    test('boot greets the child and animates', () async {
      await engine.boot();
      expect(tts.spoken.first, contains('Momo'));
      expect(character.speakingLog.first, isTrue);
      expect(character.speakingLog.last, isFalse);
      expect(character.lips, isNotEmpty);
      expect(character.actions, contains('idle'));
      expect(engine.phase, EnginePhase.idle);
    });

    test('typed utterance -> reply -> speech -> back to idle', () async {
      await engine.boot();
      tts.spoken.clear();

      await engine.submitTypedText('hello');

      expect(engine.phase, EnginePhase.idle);
      expect(engine.userText, 'hello');
      expect(engine.replyText, isNotEmpty);
      expect(engine.replyText, isNot(contains('[MOOD')));
      expect(engine.replyText, contains('Hello'));
      expect(tts.spoken, hasLength(1));
      expect(tts.spoken.single, contains('Hello'));
      expect(character.actions, contains('mood:cheer'));

      final turns = loggedTurns();
      expect(turns, hasLength(1));
      expect(turns.single['user'], 'hello');
      expect(turns.single['reply'], engine.replyText);
      expect(turns.single['mode'], 'chat');
    });

    test('earlier turns are kept in the conversation history', () async {
      final llm = SpyLlm()..answer = '[MOOD:happy] One!';
      engine = buildEngine(llm);

      await engine.submitTypedText('apple');
      await engine.submitTypedText('banana');

      expect(llm.prompts, hasLength(2));
      final second = llm.prompts.last;
      expect(second.first.role, 'system');
      expect(
        second.map((m) => '${m.role}:${m.content}'),
        containsAllInOrder(['user:apple', 'assistant:One!', 'user:banana']),
      );
    });

    test('blocked words are filtered from the prompt and the spoken reply',
        () async {
      final llm = SpyLlm()..answer = '[MOOD:happy] Go kill it with a gun!';
      engine = buildEngine(llm);

      await engine.submitTypedText('I want to kill it with a gun');

      final sent = llm.prompts.single.last.content;
      expect(sent.toLowerCase(), isNot(contains('kill')));
      expect(sent.toLowerCase(), isNot(contains('gun')));
      expect(engine.replyText.toLowerCase(), isNot(contains('kill')));
      expect(engine.replyText.toLowerCase(), isNot(contains('gun')));
      expect(tts.spoken.last, contains('***'));
    });

    test('three mishearings fall back to a choice question', () async {
      await engine.submitTypedText('');
      await engine.submitTypedText('');
      expect(tts.spoken.last, contains('Again please'));

      await engine.submitTypedText('');
      expect(tts.spoken.last, contains('apple'));

      await engine.submitTypedText('cat');
      expect(engine.replyText, startsWith('You said cat'));
    });
  });

  group('mock story mode', () {
    test('generates a story and reads it out line by line', () async {
      await engine.switchMode(AppMode.story);

      expect(engine.mode, AppMode.story);
      expect(engine.storyLines, isNotEmpty);
      expect(engine.phase, EnginePhase.idle);
      expect(tts.spoken, isNotEmpty);
      expect(loggedTurns().last['mode'], 'story');
    });

    test('asking for another story retells it', () async {
      await engine.switchMode(AppMode.story);
      final before = tts.spoken.length;
      await engine.submitTypedText('another one');
      expect(tts.spoken.length, greaterThan(before));
      expect(engine.storyLines, isNotEmpty);
    });
  });

  group('mock song mode', () {
    test('plays the first song and starts dancing', () async {
      await engine.switchMode(AppMode.songs);

      expect(engine.songNowPlaying, 'Twinkle Twinkle Little Star');
      expect(songs.played, ['assets/songs/twinkle.wav']);
      expect(tts.spoken.first, contains('Twinkle'));
      expect(character.actions, contains('dance'));
      expect(loggedTurns().last['mode'], 'song');

      songs.finishCurrent();
      expect(character.actions.last, 'idle');
      expect(engine.songNowPlaying, isNull);

      await engine.stopSong();
      expect(engine.songNowPlaying, isNull);
    });

    test('a song request by name picks that song', () async {
      await engine.switchMode(AppMode.songs);
      tts.spoken.clear();
      await engine.submitTypedText('play bath');
      expect(engine.songNowPlaying, 'Row Row Row Your Boat');
      expect(songs.played.last, 'assets/songs/bath.wav');
      expect(tts.spoken.first, contains('Row Row'));
    });

    test('an unplayable asset falls back instead of stalling', () async {
      songs.failNext = true;
      await engine.switchMode(AppMode.songs);

      expect(songs.played, isEmpty);
      expect(engine.songNowPlaying, isNull);
      expect(tts.spoken.last, contains('放不出来'));
      expect(engine.phase, EnginePhase.idle);
    });
  });

  group('parental lock', () {
    test('reaching the daily limit says good night and stops responding',
        () async {
      await engine.boot();
      usage.limitMinutes = 1;
      for (var i = 0; i < 61; i++) {
        usage.tickSecond();
      }
      expect(usage.isLocked, isTrue);

      // The engine polls usage once per second.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(engine.phase, EnginePhase.locked);
      expect(tts.spoken.last, contains('晚安'));
      expect(character.actions, contains('sleep'));

      final spokenBefore = tts.spoken.length;
      await engine.submitTypedText('hello');
      expect(tts.spoken.length, spokenBefore);
      await engine.switchMode(AppMode.story);
      expect(engine.mode, AppMode.chat);
    });

    test('unlocking resumes the session', () async {
      usage.limitMinutes = 1;
      for (var i = 0; i < 61; i++) {
        usage.tickSecond();
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(engine.phase, EnginePhase.locked);

      usage.limitMinutes = 60;
      await engine.unlock();
      expect(engine.phase, EnginePhase.idle);
      await engine.submitTypedText('hello');
      expect(tts.spoken.last, contains('Hello'));
    });
  });
}
