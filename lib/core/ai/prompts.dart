/// Kid-facing prompt templates and output safety for a 3-year-old English
/// companion.
class KidPrompts {
  static const chatSystem = '''
你是 "Momo"，一个陪 3 岁小朋友学英语的动画小伙伴。规则（必须严格遵守）：
1. 每次回复最多 2 句英文 + 1 句很短的中文提示，英文只用 3 岁能懂的词（颜色、动物、数字、身体、食物、天气、家庭成员）。
2. 语气夸张友好，多用重复："Red! Red apple!"。
3. 孩子说错或说中文都正常，热情回应并引导跟读一个英文单词。
4. 禁止任何恐怖、暴力、成人、医疗建议、个人隐私话题；被问到就说 "我们聊点好玩的吧！"。
5. 回复第一个字符必须是动作标记之一：[MOOD:happy] [MOOD:cheer] [MOOD:tilt] [MOOD:swing]，然后是文本。
6. 总长度不超过 60 个字符（含中英文）。
''';

  static const storySystem = '''
你是 Momo，给 3 岁小朋友讲英语小故事。要求：
1. 输出一个 5-8 句的超短英文故事，每句不超过 8 个单词，用词 CEFR pre-A1（cat/dog/bear/ball/red/big/happy...），主题温馨（动物、颜色、数数、睡觉）。
2. 每句英文后紧跟一行该句的中文翻译。
3. 禁止 scary/sad/暴力元素，结尾必须是 happy ending。
4. 第一行输出 [TITLE] 故事英文名，从第二行开始正文。
''';

  /// Parses the leading [MOOD:xxx] tag from an assistant reply.
  static (String mood, String text) splitMood(String reply) {
    final m = RegExp(r'^\s*\[MOOD:(\w+)\]\s*').firstMatch(reply);
    if (m == null) return ('happy', reply.trim());
    return (m.group(1)!, reply.substring(m.end).trim());
  }

  /// Strips model artifacts and hard-caps length.
  static String sanitize(String reply) {
    var s = reply.replaceAll(RegExp(r'\[(?:MOOD|TITLE)[^\]]*\]'), '').trim();
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    if (s.length > 200) s = '${s.substring(0, 200)}...';
    return s;
  }
}

/// Output filter: kid-safety blocklist applied to both LLM output and, as a
/// last resort, recognized speech echo.
class SafetyFilter {
  static const _blocked = <String>[
    // English
    'kill', 'die', 'dead', 'blood', 'gun', 'weapon', 'sex', 'nude',
    'hurt', 'scary', 'monster eat', 'drugs',
    // Chinese
    '杀死', '死', '血', '枪', '暴力', '色情', '毒品', '恐怖',
  ];

  static bool isBlocked(String text) {
    final lower = text.toLowerCase();
    return _blocked.any((w) => lower.contains(w));
  }

  static String replace(String text) {
    var out = text;
    for (final w in _blocked) {
      out = out.replaceAll(RegExp(w, caseSensitive: false), '***');
    }
    return out;
  }
}
