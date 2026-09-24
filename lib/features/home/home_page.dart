import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/state/conversation_engine.dart';
import '../../core/state/state_providers.dart';
import '../parent/parent_pages.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _consentAnswered = false;
  final _textCtl = TextEditingController();

  @override
  void dispose() {
    _textCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(engineProvider);
    final character = ref.watch(characterControllerProvider);
    ref.listen<ConversationEngine>(engineProvider, (_, __) => setState(() {}));

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFBEE8FF),
                  Color(0xFFFFF6D8),
                  Color(0xFFFFE0EC)
                ],
              ),
            ),
          ),
          WebViewWidget(controller: character.controller),
          SafeArea(
            child: Column(
              children: [
                const _TopBar(),
                const Spacer(),
                _SubtitleBar(engine: engine),
                const SizedBox(height: 8),
                _ModeBar(engine: engine, textCtl: _textCtl),
                const SizedBox(height: 10),
              ],
            ),
          ),
          if (!engine.micMode &&
              !ref.watch(usageTrackerProvider).consentGiven &&
              !_consentAnswered)
            _ConsentOverlay(
                engine: engine,
                onDone: () => setState(() => _consentAnswered = true)),
          if (engine.phase == EnginePhase.locked) const _LockOverlay(),
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineProvider);
    final listening = engine.phase == EnginePhase.listening ||
        engine.phase == EnginePhase.choosing;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: listening ? Colors.redAccent : Colors.greenAccent,
              boxShadow: [
                BoxShadow(
                  color: (listening ? Colors.red : Colors.green)
                      .withValues(alpha: listening ? 0.6 : 0.3),
                  blurRadius: listening ? 14 : 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            listening
                ? '我在听哦…'
                : engine.micMode
                    ? '麦克风已开启'
                    : '文字模式',
            style: const TextStyle(color: Color(0xFF5A6B7A), fontSize: 14),
          ),
          const Spacer(),
          Text(
            '剩余 ${engine.usage.remainingSeconds() ~/ 60} 分钟',
            style: const TextStyle(color: Color(0xFF8A97A5), fontSize: 13),
          ),
          const SizedBox(width: 10),
          InkWell(
            onTap: () {
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const PinGate()));
            },
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.settings, color: Color(0xFF8A97A5)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtitleBar extends StatelessWidget {
  final ConversationEngine engine;
  const _SubtitleBar({required this.engine});

  @override
  Widget build(BuildContext context) {
    final text = engine.replyText.isNotEmpty
        ? engine.replyText
        : engine.userText.isNotEmpty
            ? '你说：$userHint'
            : (engine.songNowPlaying ?? '');
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(
          engine.songNowPlaying != null && engine.replyText.isEmpty
              ? '🎵 ${engine.songNowPlaying}'
              : text,
          key: ValueKey(text),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF35485C),
            fontSize: 30,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
      ),
    );
  }

  String get userHint => engine.userText;
}

class _ModeBar extends ConsumerWidget {
  final ConversationEngine engine;
  final TextEditingController textCtl;
  const _ModeBar({required this.engine, required this.textCtl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mock = !engine.micMode;
    return Column(
      children: [
        Wrap(
          spacing: 14,
          alignment: WrapAlignment.center,
          children: [
            _ModeButton(
              label: '聊天',
              emoji: '🗣️',
              selected: engine.mode == AppMode.chat,
              autofocus: true,
              onTap: () => engine.switchMode(AppMode.chat),
            ),
            _ModeButton(
              label: '故事',
              emoji: '📖',
              selected: engine.mode == AppMode.story,
              onTap: () => engine.switchMode(AppMode.story),
            ),
            _ModeButton(
              label: '儿歌',
              emoji: '🎵',
              selected: engine.mode == AppMode.songs,
              onTap: () => engine.switchMode(AppMode.songs),
            ),
            if (engine.mode == AppMode.songs)
              for (final s in engine.config.songs)
                _ChipButton(
                  label: s.titleCn.isEmpty ? s.title : s.titleCn,
                  onTap: () => engine.playSong(s.id),
                ),
          ],
        ),
        if (mock)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: textCtl,
                    decoration: const InputDecoration(
                      hintText: '（文字模式）替小主人告诉 Momo…',
                      filled: true,
                      fillColor: Colors.white54,
                      border: OutlineInputBorder(
                          borderSide: BorderSide.none,
                          borderRadius: BorderRadius.all(Radius.circular(24))),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final t = textCtl.text.trim();
                    if (t.isEmpty) return;
                    textCtl.clear();
                    unawaited(engine.submitTypedText(t));
                  },
                  child: const Text('说'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ModeButton extends StatefulWidget {
  final String label;
  final String emoji;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  const _ModeButton({
    required this.label,
    required this.emoji,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<_ModeButton> createState() => _ModeButtonState();
}

class _ModeButtonState extends State<_ModeButton> {
  final _focusNode = FocusNode();
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _focused ? 1.12 : (widget.selected ? 1.06 : 1.0),
      duration: const Duration(milliseconds: 160),
      child: ElevatedButton(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onFocusChange: (f) => setState(() => _focused = f),
        onPressed: widget.onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor:
              widget.selected ? const Color(0xFFFFB74D) : Colors.white,
          foregroundColor: const Color(0xFF35485C),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          side: _focused
              ? const BorderSide(width: 4, color: Color(0xFF1565C0))
              : BorderSide.none,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(26))),
        ),
        child: Text('${widget.emoji} ${widget.label}',
            style: const TextStyle(fontSize: 18)),
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _ChipButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 15)),
      backgroundColor: Colors.white70,
      onPressed: onTap,
    );
  }
}

class _ConsentOverlay extends ConsumerStatefulWidget {
  final ConversationEngine engine;
  final VoidCallback onDone;
  const _ConsentOverlay({required this.engine, required this.onDone});

  @override
  ConsumerState<_ConsentOverlay> createState() => _ConsentOverlayState();
}

class _ConsentOverlayState extends ConsumerState<_ConsentOverlay> {
  bool _agreed = false;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 60),
        color: Colors.white.withValues(alpha: 0.96),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('首次使用需要家长确认',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: _agreed,
                onChanged: (v) => setState(() => _agreed = v ?? false),
                title: const Text('我同意开启麦克风', style: TextStyle(fontSize: 15)),
                subtitle: const Text(
                    '只有检测到我说话时，语音片段才会发送到语音识别服务转成文字；应用只保存对话文字记录，不保存我的声音。',
                    style: TextStyle(fontSize: 13, height: 1.4)),
                controlAffinity: ListTileControlAffinity.leading,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  OutlinedButton(
                    onPressed: () {
                      ref.read(usageTrackerProvider).consentGiven = false;
                      widget.onDone();
                    },
                    child: const Text('先用文字模式'),
                  ),
                  FilledButton(
                    autofocus: true,
                    onPressed: _agreed
                        ? () async {
                            ref.read(usageTrackerProvider).consentGiven = true;
                            try {
                              await widget.engine.enableMic();
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('麦克风不可用：$e')));
                              }
                            }
                            widget.onDone();
                          }
                        : null,
                    child: const Text('开启麦克风'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LockOverlay extends ConsumerWidget {
  const _LockOverlay();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xE6141B2D),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🌙', style: TextStyle(fontSize: 72)),
              const SizedBox(height: 12),
              const Text('今天玩到这里啦，晚安！',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const PinGate())),
                child:
                    const Text('家长解锁', style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
