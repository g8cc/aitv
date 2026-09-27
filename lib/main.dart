import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'character/character_controller.dart';
import 'core/config/app_config.dart';
import 'core/state/conversation_log.dart';
import 'core/state/mic_settings.dart';
import 'core/state/pin_store.dart';
import 'core/state/state_providers.dart';
import 'core/state/usage_tracker.dart';
import 'core/providers/provider_registry.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final config = await AppConfig.load();
  final prefs = await SharedPreferences.getInstance();
  final usage = UsageTracker(prefs,
      defaultLimitMinutes: config.dailyLimitMinutes);
  final character = CharacterController();

  runApp(ProviderScope(
    overrides: [
      appConfigProvider.overrideWithValue(config),
      characterControllerProvider.overrideWithValue(character),
      usageTrackerProvider.overrideWithValue(usage),
      conversationLogProvider.overrideWithValue(ConversationLog()),
      pinStoreProvider.overrideWithValue(PinStore(prefs, config.defaultPin)),
      micSettingsProvider.overrideWithValue(MicSettings(prefs)),
    ],
    child: const AiTvApp(),
  ));
}
