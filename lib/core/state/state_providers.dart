import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:aitv/character/character_controller.dart';
import '../audio/audio_input.dart';
import '../audio/mic_service.dart';
import '../audio/song_player.dart';
import '../providers/provider_registry.dart';
import 'conversation_engine.dart';
import 'conversation_log.dart';
import 'mic_settings.dart';
import 'pin_store.dart';
import 'usage_tracker.dart';

final characterControllerProvider = Provider<CharacterController>((_) {
  throw UnimplementedError('overridden in main');
});

final usageTrackerProvider = Provider<UsageTracker>((_) {
  throw UnimplementedError('overridden in main');
});

final conversationLogProvider = Provider<ConversationLog>((_) {
  throw UnimplementedError('overridden in main');
});

final pinStoreProvider = Provider<PinStore>((_) {
  throw UnimplementedError('overridden in main');
});

final micSettingsProvider = Provider<MicSettings>((_) {
  throw UnimplementedError('overridden in main');
});

/// The microphone the parent selected, or the system default device.
MicSource buildMicSource(MicSettings mic, {required bool preferred}) =>
    preferred && mic.usesNativeDevice
        ? NativeMic(inputIndex: mic.inputIndex, inputName: mic.inputName)
        : MicService();

final engineProvider = ChangeNotifierProvider<ConversationEngine>((ref) {
  final tts = ref.watch(ttsProvider);
  final engine = ConversationEngine(
    config: ref.watch(appConfigProvider),
    llm: ref.watch(llmProvider),
    asr: ref.watch(asrProvider),
    tts: tts,
    character: ref.watch(characterControllerProvider),
    usage: ref.watch(usageTrackerProvider),
    log: ref.watch(conversationLogProvider),
    songs: JustAudioSongPlayer(),
    micFactory: ({required bool preferred}) =>
        buildMicSource(ref.read(micSettingsProvider), preferred: preferred),
  );
  ref.onDispose(() => unawaited(tts.dispose()));
  unawaited(engine.boot());
  return engine;
});
