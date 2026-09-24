import 'dart:async';

import '../llm_provider.dart';

/// Offline rule-based companion used in mock mode (no API key required).
/// Returns replies tagged with a mood so the character animates.
class MockLlm implements LlmProvider {
  final List<String> _topics = [
    'Apple! A red apple. 苹果',
    'Look, a cat! Cat says meow. 小猫',
    'One, two, three! 数一数',
    'Blue sky! Can you say blue? 蓝色',
    'Big ball! Bounce bounce. 大球',
    'Happy duck! Quack quack. 小鸭子',
    'Yummy banana! Num num. 香蕉',
    'Two little birds. Tweet tweet! 两只鸟',
  ];
  int _i = 0;

  @override
  Future<String> complete(List<ChatMessage> messages) async {
    final last = messages.isEmpty ? '' : messages.last.content;
    return replyFor(last);
  }

  @override
  Stream<String> streamChat(List<ChatMessage> messages) async* {
    final last = messages.isEmpty ? '' : messages.last.content;
    final r = replyFor(last);
    for (final part in _chunk(r)) {
      await Future.delayed(const Duration(milliseconds: 40));
      yield part;
    }
  }

  String replyFor(String user) {
    final u = user.toLowerCase();
    if (u.contains('hello') || u.contains('hi') || u.contains('你好')) {
      return '[MOOD:cheer] Hello! I am Momo! Wave hello! 你好呀';
    }
    if (u.contains('song') || u.contains('music') || u.contains('歌')) {
      return '[MOOD:swing] Let us sing a song! 我们一起唱歌吧';
    }
    if (u.contains('story') || u.contains('故事')) {
      return '[MOOD:tilt] Once upon a time, a little star. 从前有小星星';
    }
    if (u.contains('bye') || u.contains('goodbye') || u.contains('再见')) {
      return '[MOOD:happy] Bye bye! See you soon! 再见啦';
    }
    final t = _topics[_i % _topics.length];
    _i++;
    return '[MOOD:happy] $t';
  }

  List<String> _chunk(String s) {
    final words = s.split(' ');
    final out = <String>[];
    for (var i = 0; i < words.length; i += 3) {
      out.add('${words.sublist(i, (i + 3).clamp(0, words.length)).join(' ')} ');
    }
    return out;
  }
}
