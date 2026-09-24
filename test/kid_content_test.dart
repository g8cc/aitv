import 'package:aitv/core/ai/prompts.dart';
import 'package:aitv/core/providers/llm_provider.dart';
import 'package:aitv/core/providers/mock/mock_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KidPrompts', () {
    test('splits a leading mood tag', () {
      final (mood, text) = KidPrompts.splitMood('[MOOD:cheer]  Hello there!');
      expect(mood, 'cheer');
      expect(text, 'Hello there!');
    });

    test('missing tag defaults to happy and keeps the text', () {
      final (mood, text) = KidPrompts.splitMood('One two three!');
      expect(mood, 'happy');
      expect(text, 'One two three!');
    });

    test('sanitize strips tags and newlines, caps length', () {
      final s = KidPrompts.sanitize('[MOOD:swing] Red!\n[TITLE x] Apple');
      expect(s, 'Red! Apple');
      expect(KidPrompts.sanitize('a' * 500).length, 203);
    });

    test('system prompts demand the mood tag and short output', () {
      expect(KidPrompts.chatSystem, contains('[MOOD:'));
      expect(KidPrompts.storySystem, contains('[TITLE]'));
    });
  });

  group('SafetyFilter', () {
    test('blocks english and chinese terms', () {
      expect(SafetyFilter.isBlocked('a big Gun'), isTrue);
      expect(SafetyFilter.isBlocked('这个故事很恐怖'), isTrue);
      expect(SafetyFilter.isBlocked('Red apple!'), isFalse);
    });

    test('replace masks the term only', () {
      expect(SafetyFilter.replace('the gun is here'), 'the *** is here');
    });
  });

  group('MockLlm offline replies', () {
    test('every reply carries a mood tag so the character animates', () {
      final llm = MockLlm();
      for (final input in [
        'hello',
        'sing a song',
        'story please',
        'bye',
        '',
        'gdgsf',
        'apple',
      ]) {
        final (mood, text) = KidPrompts.splitMood(llm.replyFor(input));
        expect(text.isNotEmpty, isTrue, reason: input);
        expect(['happy', 'cheer', 'tilt', 'swing'], contains(mood),
            reason: input);
      }
    });

    test('known intents map to their topic', () {
      final llm = MockLlm();
      expect(llm.replyFor('Hello!').toLowerCase(), contains('momo'));
      expect(llm.replyFor('我想听歌'), contains('sing'));
      expect(llm.replyFor('讲个故事'), contains('star'));
    });

    test('streaming chunks reassemble into the full reply', () async {
      final llm = MockLlm();
      final buf = StringBuffer();
      await for (final part in llm.streamChat([ChatMessage('user', 'hi')])) {
        buf.write(part);
      }
      expect(buf.toString().trim(), llm.replyFor('hi').trim());
    });
  });
}
