import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../providers/alibaba/alibaba_asr.dart';
import '../providers/alibaba/alibaba_tts.dart';
import '../providers/llm_provider.dart';
import '../providers/mock/mock_llm.dart';
import '../providers/volc/volc_asr.dart';
import '../providers/volc/volc_tts.dart';
import '../providers/asr_provider.dart';
import '../providers/tts_provider.dart';

final appConfigProvider = Provider<AppConfig>((_) {
  throw UnimplementedError('overridden in main');
});

final llmProvider = Provider<LlmProvider>((ref) {
  final cfg = ref.watch(appConfigProvider);
  switch (cfg.provider) {
    case 'alibaba':
      if (cfg.alibaba.ready) {
        return OpenAiCompatLlm(
          baseUrl: cfg.alibaba.llmBaseUrl,
          apiKey: cfg.alibaba.apiKey,
          model: cfg.alibaba.llmModel,
        );
      }
      break;
    case 'volc':
      if (cfg.volc.llmReady) {
        return OpenAiCompatLlm(
          baseUrl: cfg.volc.llmBaseUrl,
          apiKey: cfg.volc.arkApiKey,
          model: cfg.volc.llmModel,
        );
      }
      break;
  }
  return MockLlm();
});

final asrProvider = Provider<AsrProvider>((ref) {
  final cfg = ref.watch(appConfigProvider);
  switch (cfg.provider) {
    case 'alibaba':
      if (cfg.alibaba.ready) return AlibabaAsrProvider(cfg.alibaba);
      break;
    case 'volc':
      if (cfg.volc.asrReady) return VolcAsrProvider(cfg.volc);
      break;
  }
  return MockAsrProvider();
});

final ttsProvider = Provider<TtsProvider>((ref) {
  final cfg = ref.watch(appConfigProvider);
  switch (cfg.provider) {
    case 'alibaba':
      if (cfg.alibaba.ready) {
        return CloudTtsProvider(AlibabaTtsFetcher(cfg.alibaba));
      }
      break;
    case 'volc':
      if (cfg.volc.ttsReady) return CloudTtsProvider(VolcTtsFetcher(cfg.volc));
      break;
  }
  return MockTtsProvider();
});

/// True when running in mock/offline mode (system TTS + typed input).
final isMockModeProvider = Provider<bool>((ref) {
  final llm = ref.watch(llmProvider);
  return llm is MockLlm;
});
