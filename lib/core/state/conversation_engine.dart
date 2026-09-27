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
  StreamSubscription<Uint8List>? _frameSub;
  StreamSubscription<VadEvent>? _vadSub;
  AsrSession? _session;
  bool _connecting = false;
  final List<Uint8List> _pendingFrames = [];
  StreamSubscription<AsrResult>? _asrSub;
  Timer? _usageTimer;
  Timer? _asrRetryTimer;
  Future<void>? _openingMic;
  int _asrGeneration = 0;
  int _misfireCount = 0;
  List<String> _choiceOptions = const [];
  int _turn = 0;
  bool _booted = false;
  bool _disposed = false;
  bool _suspended = false;
  bool _micActive = false;
  bool _resumeMicOnForeground = false;
  int? _lastRemainingMinute;

  /// Generation counter: every mode switch, lock, unlock, story and song
  /// bump it. In-flight async turns capture the value on entry and abandon
  /// their remaining side effects once it moves, so a stale turn can never
  /// steal the phase, the character or the lip-sync stream from a newer one.
  int _gen = 0;

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
    if (_mic != null || _suspended || _disposed) return;
    final opening = _openingMic;
    if (opening != null) {
      await opening;
      return;
    }

    final future = _enableMic();
    _openingMic = future;
    try {
      await future;
    } finally {
      if (identical(_openingMic, future)) _openingMic = null;
    }
  }

  Future<void> _enableMic() async {
    final generation = _gen;
    final m = await _openMic();
    if (_disposed ||
        _suspended ||
        generation != _gen ||
        usage.isLocked ||
        mode != AppMode.chat) {
      await m.dispose();
      return;
    }
    _mic = m;
    _micActive = true;
    _vadSub = m.vadEvents.listen(_onVad,
        onError: (Object e) => debugPrint('vad stream error: $e'));
    _frameSub = m.frames.listen(_onFrame,
        onError: (Object e) => debugPrint('mic frame error: $e'));
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
  Future<void> pauseMic() async {
    await _stopAsrSession();
    await _mic?.stop();
    _micActive = false;
    if (phase == EnginePhase.listening || phase == EnginePhase.choosing) {
      phase = EnginePhase.idle;
      _notify();
    }
  }

  /// Re-open capture, e.g. after the parent picked another input device.
  Future<void> restartMic() async {
    final old = _mic;
    if (old == null) return;
    await _stopAsrSession();
    _mic = null;
    _micActive = false;
    await _vadSub?.cancel();
    await _frameSub?.cancel();
    _vadSub = null;
    _frameSub = null;
    await old.dispose();
    await enableMic();
  }

  /// Releases device/network/audio resources while the TV app is backgrounded.
  /// The selected microphone object is kept so resume can reuse the same
  /// device without rebuilding the whole conversation state.
  Future<void> suspend() async {
    if (_disposed || _suspended) return;
    _suspended = true;
    _resumeMicOnForeground = _micActive;
    usage.pause();
    _gen++;
    await llm.cancel();
    await _stopAsrSession();
    await _mic?.stop();
    _micActive = false;
    await _stopSong();
    await tts.stop();
    character.setSpeaking(false);
    character.playAction('idle');
    if (phase != EnginePhase.locked) {
      phase = EnginePhase.idle;
      _notify();
    }
  }

  Future<void> resume() async {
    if (_disposed) return;
    if (!_suspended) return;
    _suspended = false;
    final shouldResumeMic = _resumeMicOnForeground;
    _resumeMicOnForeground = false;
    final generation = _gen;
    usage.resume();
    if (!shouldResumeMic ||
        _mic == null ||
        usage.isLocked ||
        phase == EnginePhase.locked ||
        mode != AppMode.chat) {
      return;
    }
    try {
      await _mic!.start();
      if (_suspended || generation != _gen) {
        await _mic!.stop();
        return;
      }
      _micActive = true;
      _enterListening();
    } catch (e) {
      debugPrint('microphone resume failed: $e');
    }
  }

  // ---------------- mode switching ----------------

  Future<void> switchMode(AppMode m) async {
    if (phase == EnginePhase.locked) return;
    if (m == mode && m != AppMode.songs) return;
    // A newer mode owns the character from here on; cut any audio the old
    // mode is still playing.
    final generation = ++_gen;
    mode = m;
    _history.clear();
    storyLines = const [];
    userText = '';
    replyText = '';
    _misfireCount = 0;
    _choiceOptions = const [];
    _notify();
    await llm.cancel();
    await _stopAsrSession();
    await tts.stop();
    if (generation != _gen) return;
    if (m != AppMode.chat) {
      await _mic?.stop();
      _micActive = false;
    }
    await _stopSong();
    switch (m) {
      case AppMode.chat:
        character.mood('happy');
        await speakTurn('[MOOD:happy] Let us talk! 我们来说英语吧！', 'happy');
        if (generation == _gen && !_suspended && _mic != null) {
          await _mic!.start();
          _micActive = true;
          _enterListening();
        }
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
      if (usage.isPaused) return;
      usage.tickSecond();
      final remainingMinute = usage.remainingSeconds() ~/ 60;
      if (_lastRemainingMinute != remainingMinute) {
        _lastRemainingMinute = remainingMinute;
        _notify();
      }
      if (usage.isLocked && phase != EnginePhase.locked) {
        unawaited(_enterLock());
      }
    });
  }

  Future<void> _enterLock() async {
    // Abandon every in-flight turn before the good-night line starts, so a
    // late LLM/TTS callback cannot speak or move the phase after the lock.
    _gen++;
    final g = _gen;
    await llm.cancel();
    phase = EnginePhase.locked;
    await _stopAsrSession();
    await _mic?.stop();
    _micActive = false;
    await _stopSong();
    await tts.stop();
    character.setSpeaking(false);
    await speakTurn('[MOOD:sleep] 时间到啦，晚安！Good night!', 'sleep');
    if (g == _gen) character.playAction('sleep');
    _notify();
  }

  /// Parent unlock after extending the daily limit. Only meaningful while the
  /// lock is actually held; otherwise it would stomp a running turn.
  Future<void> unlock() async {
    if (phase != EnginePhase.locked) {
      _notify();
      return;
    }
    _gen++;
    phase = EnginePhase.idle;
    character.setSpeaking(false);
    character.playAction('idle');
    if (usage.isLocked) {
      _notify();
      return;
    }
    if (_mic != null && !_suspended) {
      // _enterLock stopped capture; the mic has to come back with the session.
      try {
        await _mic!.start();
        _micActive = true;
        _enterListening();
      } catch (e) {
        debugPrint('microphone unlock failed: $e');
      }
    }
    _notify();
  }

  // ---------------- voice pipeline ----------------

  /// True when a recognition session should be running right now.
  bool get _shouldListen =>
      _mic != null &&
      !usage.isLocked &&
      phase != EnginePhase.locked &&
      mode == AppMode.chat &&
      (phase == EnginePhase.listening || phase == EnginePhase.choosing);

  void _onFrame(Uint8List frame) {
    if (_disposed) return;
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
    if (_disposed) return;
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
    final generation = _asrGeneration;
    var stale = false;
    _asrRetryTimer?.cancel();
    await _asrSub?.cancel();
    _asrSub = null;
    await _session?.cancel();
    _session = null;
    try {
      final s = await asr.startSession();
      if (generation != _asrGeneration || !_shouldListen || _disposed) {
        stale = true;
        await s.cancel();
        return;
      }
      _session = s;
      _asrSub = s.results.listen(
        (r) => _onAsr(s, r),
        onError: (Object e) => _onSessionEnded(s, error: e),
        onDone: () => _onSessionEnded(s),
      );
      // Whatever was captured during the handshake goes in now, so the first
      // words are not clipped.
      for (final f in _pendingFrames) {
        s.addFrame(f);
      }
      _pendingFrames.clear();
    } catch (e) {
      debugPrint('asr session failed: $e');
      _session = null;
      // Keep the loop alive on a transient handshake failure instead of
      // waiting for the next utterance to notice.
      if (_shouldListen && !_disposed) _scheduleAsrRetry();
    } finally {
      _connecting = false;
      if ((stale || _session == null) && _shouldListen && !_disposed) {
        _scheduleAsrRetry();
      }
    }
  }

  void _scheduleAsrRetry() {
    _asrRetryTimer?.cancel();
    _asrRetryTimer = Timer(const Duration(seconds: 1), () {
      if (_disposed || _connecting || _session != null || !_shouldListen) {
        return;
      }
      unawaited(_startAsrSession());
    });
  }

  void _onAsr(AsrSession s, AsrResult r) {
    if (_disposed || !identical(_session, s) || !_shouldListen) return;
    if (!r.isFinal) {
      userText = r.text;
      _notify();
      return;
    }
    _session = null;
    final sub = _asrSub;
    _asrSub = null;
    unawaited(sub?.cancel() ?? Future<void>.value());
    unawaited(s.cancel());
    unawaited(_handleFinalUtterance(r.text, expectedGeneration: _gen));
  }

  Future<void> _stopAsrSession() async {
    _asrGeneration++;
    _asrRetryTimer?.cancel();
    _asrRetryTimer = null;
    _pendingFrames.clear();

    final sub = _asrSub;
    _asrSub = null;
    await sub?.cancel();

    final session = _session;
    _session = null;
    await session?.cancel();
  }

  /// The transport closed (task-finished, socket drop, error) without a final
  /// result. Drop the dead session and, if we are still supposed to be
  /// listening, open a fresh one — otherwise the loop wedges forever.
  void _onSessionEnded(AsrSession s, {Object? error}) {
    if (!identical(_session, s)) return;
    _session = null;
    if (error != null) debugPrint('asr session ended: $error');
    if (_shouldListen && !_disposed) {
      if (_connecting) {
        _scheduleAsrRetry();
      } else {
        unawaited(_startAsrSession());
      }
    }
  }

  Future<void> _handleFinalUtterance(String text,
      {int? expectedGeneration}) async {
    final generation = expectedGeneration ?? _gen;
    if (generation != _gen ||
        phase == EnginePhase.locked ||
        mode != AppMode.chat) {
      return;
    }
    final t = text.trim();
    if (t.isEmpty) {
      _misfireCount++;
      if (_misfireCount >= 3) {
        await _offerChoices();
      } else {
        await speakTurn('[MOOD:tilt] 你说什么呀？Again please?', 'tilt');
        if (generation == _gen) _enterListening();
      }
      _notify();
      return;
    }
    _misfireCount = 0;
    userText = t;
    await _onUserText(t, expectedGeneration: generation);
  }

  /// Keyboard fallback (mock/demo/test): feed text as if heard.
  Future<void> submitTypedText(String text) async {
    if (_disposed ||
        phase == EnginePhase.locked ||
        (phase != EnginePhase.idle &&
            phase != EnginePhase.listening &&
            phase != EnginePhase.choosing)) {
      return;
    }
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

  Future<void> _onUserText(String text, {int? expectedGeneration}) async {
    final g = expectedGeneration ?? _gen;
    if (g != _gen) return;
    phase = EnginePhase.thinking;
    _notify();

    if (_choiceOptions.isNotEmpty) {
      final picked = _matchChoice(text);
      _choiceOptions = const [];
      if (picked != null) {
        if (g != _gen) return;
        replyText = 'You said $picked! ${_choiceCn(picked)}';
        await log.append(mode: mode.name, user: userText, reply: replyText);
        await speakTurn(replyText, 'cheer');
        if (g == _gen && !usage.isLocked && _mic != null) _enterListening();
        _notify();
        return;
      }
    }

    final safeInput = SafetyFilter.replace(text);
    _history.add(ChatMessage('user', safeInput));
    if (_history.length > 20) {
      _history.removeRange(0, _history.length - 20);
    }
    try {
      final raw = await llm.complete([
        ChatMessage('system', KidPrompts.chatSystem),
        ..._history,
      ]).timeout(const Duration(seconds: 20));
      if (g != _gen) return;
      final (mood, plain) = KidPrompts.splitMood(raw);
      final cleaned = SafetyFilter.replace(KidPrompts.sanitize(plain));
      _history.add(ChatMessage('assistant', cleaned));
      replyText = cleaned;
      await log.append(mode: mode.name, user: userText, reply: cleaned);
      await speakTurn(cleaned, mood);
    } catch (e) {
      if (g != _gen) return;
      debugPrint('llm failed: $e');
      replyText = '我走神啦，再说一次好吗？Again please?';
      await speakTurn(replyText, 'tilt');
    }
    if (g == _gen && !usage.isLocked && _mic != null) _enterListening();
    _notify();
  }

  String _choiceCn(String c) => switch (c) {
        'apple' => '苹果！',
        'cat' => '小猫！',
        _ => '',
      };

  Future<void> speakTurn(String tagged, String? moodToken) async {
    if (_disposed) return;
    final g = _gen;
    // The lock's good-night line runs while the phase stays `locked`, so the
    // child cannot slip input in through checks that only look at the phase.
    final speaksOverLock = phase == EnginePhase.locked;
    final (_, text) = KidPrompts.splitMood(tagged);
    final speakable = SafetyFilter.replace(text);
    if (!speaksOverLock) {
      phase = EnginePhase.speaking;
      _notify();
    }
    character.setSpeaking(true);
    if (moodToken != null) character.mood(moodToken);
    // Each turn owns its own lip-sync subscription: a shared one would let a
    // finishing turn cancel the stream of the turn that replaced it.
    final lipSub = tts.amplitudes.listen(character.setLip);
    try {
      await tts.speak(speakable).timeout(
            const Duration(seconds: 90),
            // The provider keeps synthesizing after our timeout; cut it so a
            // ghost utterance cannot start talking over the next turn.
            onTimeout: () => tts.stop(),
          );
    } catch (e) {
      debugPrint('tts failed: $e');
    }
    await lipSub.cancel();
    // A newer generation owns the character now; skip every side effect.
    if (g != _gen) return;
    character.setSpeaking(false);
    character.playAction('idle');
    if (!speaksOverLock && phase == EnginePhase.speaking) {
      phase = usage.isLocked ? EnginePhase.locked : EnginePhase.idle;
    }
    _notify();
  }

  // ---------------- choice fallback ----------------

  Future<void> _offerChoices() async {
    final g = _gen;
    _choiceOptions = ['apple', 'cat'];
    await speakTurn('[MOOD:cheer] Say "apple" 或者 "cat"！', 'cheer');
    if (g == _gen) _enterListening();
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
    if (_disposed || phase == EnginePhase.locked) return;
    _gen++;
    final g = _gen;
    await llm.cancel();
    await _stopAsrSession();
    await tts.stop();
    await _stopSong();
    if (g != _gen || _disposed) {
      return;
    }
    phase = EnginePhase.thinking;
    _notify();
    try {
      final raw = await llm.complete([
        ChatMessage('system', KidPrompts.storySystem),
        ChatMessage('user', _storySeed(_turn++)),
      ]).timeout(const Duration(seconds: 30));
      if (g != _gen) return;
      storyLines = raw
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('[TITLE]'))
          .map(KidPrompts.sanitize)
          .map(SafetyFilter.replace)
          .take(16)
          .toList();
      await log.append(mode: 'story', reply: storyLines.join(' | '));
      for (final line in storyLines) {
        // A mode switch, a new story or the daily lock abandons this one.
        if (g != _gen || phase == EnginePhase.locked) return;
        final en = _extractEnglish(line);
        if (en.isNotEmpty) {
          await speakTurn('[MOOD:happy] $en', 'happy');
        }
      }
      if (g != _gen || phase == EnginePhase.locked) return;
      await speakTurn('[MOOD:cheer] The end! 再说一个故事吧！', 'cheer');
    } catch (e) {
      if (g != _gen) return;
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
    if (_disposed || phase == EnginePhase.locked || config.songs.isEmpty) {
      return;
    }
    _gen++;
    final g = _gen;
    final song = config.songs
        .firstWhere((s) => s.id == id, orElse: () => config.songs.first);
    await llm.cancel();
    await tts.stop();
    await _stopSong();
    if (g != _gen || _disposed) return;
    songNowPlaying = song.title;
    _notify();
    await log.append(mode: 'song', reply: song.title);
    await speakTurn('[MOOD:swing] ${song.title}! ${song.titleCn}', 'swing');
    if (g != _gen) return;
    character.playAction('dance');
    try {
      await songs.play(song.asset, onFinished: () {
        if (g == _gen) {
          songNowPlaying = null;
          character.playAction('idle');
          _notify();
        }
      });
    } catch (e) {
      // A wrong path in app_config.json must not stall the child-facing flow.
      debugPrint('song unavailable (${song.asset}): $e');
      if (g != _gen) return;
      songNowPlaying = null;
      character.playAction('idle');
      await speakTurn('[MOOD:tilt] 这首歌暂时放不出来，我们换一个吧', null);
      _notify();
      return;
    }
  }

  Future<void> stopSong() async {
    _gen++;
    await llm.cancel();
    await tts.stop();
    await _stopSong();
    character.setSpeaking(false);
    character.playAction('idle');
    if (phase != EnginePhase.locked) phase = EnginePhase.idle;
    _notify();
  }

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
    if (_disposed) return;
    _disposed = true;
    _suspended = true;
    usage.pause();
    _gen++;
    _asrGeneration++;
    _usageTimer?.cancel();
    _asrRetryTimer?.cancel();
    _vadSub?.cancel();
    _frameSub?.cancel();
    final asrSub = _asrSub;
    _asrSub = null;
    final session = _session;
    _session = null;
    unawaited(asrSub?.cancel() ?? Future<void>.value());
    unawaited(session?.cancel() ?? Future<void>.value());
    unawaited(llm.cancel());
    unawaited(tts.stop());
    unawaited(_mic?.dispose() ?? Future<void>.value());
    unawaited(songs.dispose());
    super.dispose();
  }
}
