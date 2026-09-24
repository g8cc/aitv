import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:aitv/character/character_controller.dart';
import '../ai/prompts.dart';
import '../audio/mic_service.dart';
import '../audio/song_player.dart';
import '../config/app_config.dart';
import '../providers/asr_provider.dart';
import '../providers/llm_provider.dart';
import '../providers/tts_provider.dart';
import 'conversation_log.dart';
import 'usage_tracker.dart';

enum AppMode { chat, story, songs }

enum EnginePhase { idle, listening, thinking, speaking, choosing, locked }

/// The platform's own choice of microphone, used when no input device was
/// selected or the selected one is gone.
MicSource _defaultMicFactory({required bool preferred}) => MicService();

/// Orchestrates: mic/VAD -> ASR -> LLM -> TTS -> character, plus story and
/// song modes, usage lock and the child-friendly confirmation flow.
class ConversationEngine extends ChangeNotifier {
  final AppConfig config;
  final LlmProvider llm;
  final AsrProvider asr;
  final TtsProvider tts;
  final CharacterDriver character;
  final UsageTracker usage;
  final ConversationLog log;
  final SongPlayer songs;

  MicSource? _mic;
  AppMode mode = AppMode.chat;
  EnginePhase phase = EnginePhase.idle;

  String userText = '';
  String replyText = '';
  String? songNowPlaying;
  List<String> storyLines = const [];

  final List<ChatMessage> _history = [];
  StreamSubscription<double>? _lipSub;
  StreamSubscription<Uint8List>? _frameSub;
  StreamSubscription<VadEvent>? _vadSub;
  AsrSession? _session;
  bool _connecting = false;
  final List<Uint8List> _pendingFrames = [];
  StreamSubscription<AsrResult>? _asrSub;
  Timer? _usageTimer;
  int _misfireCount = 0;
  List<String> _choiceOptions = const [];
  int _turn = 0;
  bool _booted = false;
  /// Builds the microphone to use: the parent's preferred input device, or the
  /// system default one.
  final MicSource Function({required bool preferred}) _micFactory;

  ConversationEngine({
    required this.config,
    required this.llm,
    required this.asr,
    required this.tts,
    required this.character,
    required this.usage,
    required this.log,
    required this.songs,
    MicSource Function({required bool preferred})? micFactory,
  }) : _micFactory = micFactory ?? _defaultMicFactory {
    _startUsageTimer();
  }

  bool get micMode => _mic != null;

  Future<void> boot() async {
    if (_booted) return;
    _booted = true;
    try {
      await character.ready.timeout(const Duration(seconds: 20));
      character.playAction('idle');
      await speakTurn('[MOOD:cheer] Hi! I am Momo! 我是Momo！', 'cheer');
    } catch (e) {
      debugPrint('character boot failed: $e');
    }
  }

  /// Called once the parent has granted microphone consent.
  Future<void> enableMic() async {
    if (_mic != null) return;
    final m = await _openMic();
    _mic = m;
    _vadSub = m.vadEvents.listen(_onVad);
    _frameSub = m.frames.listen(_onFrame);
    _enterListening();
    _notify();
  }

  /// Prefers the parent's chosen input device, but never leaves the child
  /// without a microphone: an input that has been unplugged since it was
  /// selected falls back to the system default.
  Future<MicSource> _openMic() async {
    final preferred = _micFactory(preferred: true);
    try {
      await preferred.start();
      return preferred;
    } catch (e) {
      debugPrint('preferred mic failed ($e), trying the default device');
      await preferred.dispose();
      final fallback = _micFactory(preferred: false);
      try {
        await fallback.start();
        return fallback;
      } catch (_) {
        await fallback.dispose();
        throw e;
      }
    }
  }

  /// Hands the microphone over to another capture, e.g. the parent self-check.
  Future<void> pauseMic() => _mic?.stop() ?? Future.value();

  /// Re-open capture, e.g. after the parent picked another input device.
  Future<void> restartMic() async {
    final old = _mic;
    if (old == null) return;
    _mic = null;
    await _vadSub?.cancel();
    await _frameSub?.cancel();
    _vadSub = null;
    _frameSub = null;
    await old.dispose();
    await enableMic();
  }

  // ---------------- mode switching ----------------

  Future<void> switchMode(AppMode m) async {
    if (phase == EnginePhase.locked) return;
    if (m == mode && m != AppMode.songs) return;
    mode = m;
    _history.clear();
    storyLines = const [];
    userText = '';
    replyText = '';
    _misfireCount = 0;
    _choiceOptions = const [];
    await _stopSong();
    switch (m) {
      case AppMode.chat:
        character.mood('happy');
        await speakTurn('[MOOD:happy] Let us talk! 我们来说英语吧！', 'happy');
        if (_mic != null) _enterListening();
        break;
      case AppMode.story:
        await tellStory();
        break;
      case AppMode.songs:
        if (config.songs.isNotEmpty) {
          await playSong(config.songs.first.id);
        }
        break;
    }
    _notify();
  }

  // ---------------- usage / lock ----------------

  void _startUsageTimer() {
    _usageTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      usage.tickSecond();
      if (usage.isLocked && phase != EnginePhase.locked) {
        unawaited(_enterLock());
      }
    });
  }

  Future<void> _enterLock() async {
    phase = EnginePhase.locked;
    await _mic?.stop();
    await _stopSong();
    character.setSpeaking(false);
    await speakTurn('[MOOD:sleep] 时间到啦，晚安！Good night!', 'sleep');
    character.playAction('sleep');
    _notify();
  }

  /// Parent unlock after extending the daily limit.
  Future<void> unlock() async {
    phase = EnginePhase.idle;
    character.playAction('idle');
    if (_mic != null) {
      // _enterLock stopped capture; the mic has to come back with the session.
      await _mic!.start();
      _enterListening();
    }
    _notify();
  }

  // ---------------- voice pipeline ----------------

  void _onFrame(Uint8List frame) {
    if (phase != EnginePhase.listening && phase != EnginePhase.choosing) return;
    final s = _session;
    if (s != null) {
      s.addFrame(frame);
      return;
    }
    // The ASR session is still connecting (WebSocket handshake takes a few
    // hundred ms); keep the speech so the first words are not clipped.
    if (_pendingFrames.length < 200) _pendingFrames.add(frame);
  }

  void _onVad(VadEvent e) {
    if (phase == EnginePhase.locked || mode != AppMode.chat) return;
    if (e.phase == VadPhase.start) {
      // Already capturing: restarting the session would throw away the speech
      // heard so far.
      if (_session == null &&
          (phase == EnginePhase.idle || phase == EnginePhase.listening)) {
        _enterListening();
      }
    } else if (e.phase == VadPhase.end && _session != null) {
      unawaited(_session!.finish());
    }
  }

  void _enterListening() {
    if (phase == EnginePhase.locked || mode != AppMode.chat) return;
    unawaited(_startAsrSession());
    phase =
        _choiceOptions.isEmpty ? EnginePhase.listening : EnginePhase.choosing;
    character.playAction('tilt');
    _notify();
  }

  Future<void> _startAsrSession() async {
    if (_connecting) return;
    _connecting = true;
    await _asrSub?.cancel();
    await _session?.cancel();
    try {
      final s = await asr.startSession();
      _session = s;
      _asrSub = s.results.listen(_onAsr);
      // Whatever was captured during the handshake goes in now, so the first
      // words are not clipped.
      for (final f in _pendingFrames) {
        s.addFrame(f);
      }
      _pendingFrames.clear();
    } catch (e) {
      debugPrint('asr session failed: $e');
      _session = null;
    } finally {
      _connecting = false;
    }
  }

  void _onAsr(AsrResult r) {
    if (!r.isFinal) {
      userText = r.text;
      _notify();
      return;
    }
    _session = null;
    unawaited(_handleFinalUtterance(r.text));
  }

  Future<void> _handleFinalUtterance(String text) async {
    final t = text.trim();
    if (t.isEmpty) {
      _misfireCount++;
      if (_misfireCount >= 3) {
        await _offerChoices();
      } else {
        await speakTurn('[MOOD:tilt] 你说什么呀？Again please?', 'tilt');
        _enterListening();
      }
      _notify();
      return;
    }
    _misfireCount = 0;
    userText = t;
    await _onUserText(t);
  }

  /// Keyboard fallback (mock/demo/test): feed text as if heard.
  Future<void> submitTypedText(String text) async {
    if (phase == EnginePhase.locked) return;
    switch (mode) {
      case AppMode.songs:
        final id = _matchSong(text);
        if (id != null) await playSong(id);
        return;
      case AppMode.story:
        await tellStory();
        return;
      case AppMode.chat:
        await _handleFinalUtterance(text);
        return;
    }
  }

  Future<void> _onUserText(String text) async {
    phase = EnginePhase.thinking;
    _notify();

    if (_choiceOptions.isNotEmpty) {
      final picked = _matchChoice(text);
      _choiceOptions = const [];
      if (picked != null) {
        replyText = 'You said $picked! ${_choiceCn(picked)}';
        await log.append(mode: mode.name, user: userText, reply: replyText);
        await speakTurn(replyText, 'cheer');
        _enterListening();
        _notify();
        return;
      }
    }

    final safeInput = SafetyFilter.replace(text);
    _history.add(ChatMessage('user', safeInput));
    try {
      final raw = await llm.complete([
        ChatMessage('system', KidPrompts.chatSystem),
        ..._history,
      ]).timeout(const Duration(seconds: 20));
      final (mood, plain) = KidPrompts.splitMood(raw);
      final cleaned = SafetyFilter.replace(KidPrompts.sanitize(plain));
      _history.add(ChatMessage('assistant', cleaned));
      replyText = cleaned;
      await log.append(mode: mode.name, user: userText, reply: cleaned);
      await speakTurn(cleaned, mood);
    } catch (e) {
      debugPrint('llm failed: $e');
      replyText = '我走神啦，再说一次好吗？Again please?';
      await speakTurn(replyText, 'tilt');
    }
    if (!usage.isLocked && _mic != null) _enterListening();
    _notify();
  }

  String _choiceCn(String c) => switch (c) {
        'apple' => '苹果！',
        'cat' => '小猫！',
        _ => '',
      };

  Future<void> speakTurn(String tagged, String? moodToken) async {
    final (_, text) = KidPrompts.splitMood(tagged);
    final speakable = SafetyFilter.replace(text);
    phase = EnginePhase.speaking;
    _notify();
    character.setSpeaking(true);
    if (moodToken != null) character.mood(moodToken);
    await _lipSub?.cancel();
    _lipSub = tts.amplitudes.listen(character.setLip);
    try {
      await tts
          .speak(speakable)
          .timeout(const Duration(seconds: 90), onTimeout: () async {});
    } catch (e) {
      debugPrint('tts failed: $e');
    }
    character.setSpeaking(false);
    character.playAction('idle');
    await _lipSub?.cancel();
    _lipSub = null;
    // Only this turn may end the turn: a parent unlock (or the next listening
    // session) that happened while speaking must survive.
    if (phase == EnginePhase.speaking) {
      phase = usage.isLocked ? EnginePhase.locked : EnginePhase.idle;
    }
    _notify();
  }

  // ---------------- choice fallback ----------------

  Future<void> _offerChoices() async {
    _choiceOptions = ['apple', 'cat'];
    await speakTurn('[MOOD:cheer] Say "apple" 或者 "cat"！', 'cheer');
    _enterListening();
  }

  String? _matchChoice(String heard) {
    final h = heard.toLowerCase();
    for (final c in _choiceOptions) {
      if (h.contains(c.substring(0, 2))) return c;
    }
    return null;
  }

  // ---------------- story mode ----------------

  Future<void> tellStory() async {
    phase = EnginePhase.thinking;
    _notify();
    try {
      final raw = await llm.complete([
        ChatMessage('system', KidPrompts.storySystem),
        ChatMessage('user', _storySeed(_turn++)),
      ]).timeout(const Duration(seconds: 30));
      storyLines = raw
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('[TITLE]'))
          .toList();
      await log.append(mode: 'story', reply: storyLines.join(' | '));
      for (final line in storyLines) {
        if (phase == EnginePhase.locked) return;
        final en = _extractEnglish(line);
        if (en.isNotEmpty) {
          await speakTurn('[MOOD:happy] $en', 'happy');
        }
      }
      await speakTurn('[MOOD:cheer] The end! 再说一个故事吧！', 'cheer');
    } catch (e) {
      debugPrint('story failed: $e');
      await speakTurn('[MOOD:tilt] 故事小火车暂时休息啦', null);
    }
    _notify();
  }

  static String _storySeed(int n) =>
      'little ${['cat', 'star', 'duck', 'bear', 'ball'][n % 5]}';

  static String _extractEnglish(String line) {
    final m = RegExp("[A-Za-z][A-Za-z ,.!?'-]+").firstMatch(line);
    return m?.group(0)?.trim() ?? '';
  }

  // ---------------- song mode ----------------

  Future<void> playSong(String? id) async {
    if (config.songs.isEmpty) return;
    final song = config.songs
        .firstWhere((s) => s.id == id, orElse: () => config.songs.first);
    await _stopSong();
    songNowPlaying = song.title;
    _notify();
    await log.append(mode: 'song', reply: song.title);
    await speakTurn('[MOOD:swing] ${song.title}! ${song.titleCn}', 'swing');
    character.playAction('dance');
    try {
      await songs.play(song.asset,
          onFinished: () => character.playAction('idle'));
    } catch (e) {
      // A wrong path in app_config.json must not stall the child-facing flow.
      debugPrint('song unavailable (${song.asset}): $e');
      songNowPlaying = null;
      character.playAction('idle');
      await speakTurn('[MOOD:tilt] 这首歌暂时放不出来，我们换一个吧', null);
      _notify();
      return;
    }
  }

  Future<void> stopSong() => _stopSong();

  Future<void> _stopSong() async {
    songNowPlaying = null;
    await songs.stop();
  }

  String? _matchSong(String heard) {
    final h = heard.toLowerCase();
    for (final s in config.songs) {
      if (h.contains(s.title.toLowerCase().split(' ').first) ||
          h.contains(s.id)) {
        return s.id;
      }
    }
    return null;
  }

  void _notify() => notifyListeners();

  @override
  void dispose() {
    _usageTimer?.cancel();
    _lipSub?.cancel();
    _vadSub?.cancel();
    _frameSub?.cancel();
    _asrSub?.cancel();
    _mic?.dispose();
    songs.dispose();
    super.dispose();
  }
}
