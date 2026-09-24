import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class AlibabaConfig {
  final String apiKey;
  final String llmBaseUrl;
  final String llmModel;
  final String asrModel;
  final int asrSampleRate;
  final String ttsModel;
  final String ttsVoice;
  final int ttsSampleRate;

  const AlibabaConfig({
    this.apiKey = '',
    this.llmBaseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    this.llmModel = 'qwen-plus',
    this.asrModel = 'paraformer-realtime-v2',
    this.asrSampleRate = 16000,
    this.ttsModel = 'cosyvoice-v1',
    this.ttsVoice = 'longxiaochun',
    this.ttsSampleRate = 24000,
  });

  factory AlibabaConfig.fromJson(Map<String, dynamic> j) => AlibabaConfig(
        apiKey: j['api_key'] as String? ?? '',
        llmBaseUrl: j['llm_base_url'] as String? ??
            'https://dashscope.aliyuncs.com/compatible-mode/v1',
        llmModel: j['llm_model'] as String? ?? 'qwen-plus',
        asrModel: j['asr_model'] as String? ?? 'paraformer-realtime-v2',
        asrSampleRate: j['asr_sample_rate'] as int? ?? 16000,
        ttsModel: j['tts_model'] as String? ?? 'cosyvoice-v1',
        ttsVoice: j['tts_voice'] as String? ?? 'longxiaochun',
        ttsSampleRate: j['tts_sample_rate'] as int? ?? 24000,
      );

  bool get ready => apiKey.isNotEmpty;
}

class VolcConfig {
  final String arkApiKey;
  final String llmBaseUrl;
  final String llmModel;
  final String ttsAppId;
  final String ttsAccessToken;
  final String ttsCluster;
  final String ttsVoiceType;
  final int ttsSampleRate;
  final String asrAppId;
  final String asrAccessToken;
  final String asrCluster;

  const VolcConfig({
    this.arkApiKey = '',
    this.llmBaseUrl = 'https://ark.cn-beijing.volces.com/api/v3',
    this.llmModel = 'doubao-seed-1-6-250615',
    this.ttsAppId = '',
    this.ttsAccessToken = '',
    this.ttsCluster = 'volcano_tts',
    this.ttsVoiceType = 'S_Zh_MassqVlog',
    this.ttsSampleRate = 24000,
    this.asrAppId = '',
    this.asrAccessToken = '',
    this.asrCluster = 'streaming_asr',
  });

  factory VolcConfig.fromJson(Map<String, dynamic> j) => VolcConfig(
        arkApiKey: j['ark_api_key'] as String? ?? '',
        llmBaseUrl: j['llm_base_url'] as String? ??
            'https://ark.cn-beijing.volces.com/api/v3',
        llmModel: j['llm_model'] as String? ?? 'doubao-seed-1-6-250615',
        ttsAppId: j['tts_app_id'] as String? ?? '',
        ttsAccessToken: j['tts_access_token'] as String? ?? '',
        ttsCluster: j['tts_cluster'] as String? ?? 'volcano_tts',
        ttsVoiceType: j['tts_voice_type'] as String? ?? 'S_Zh_MassqVlog',
        ttsSampleRate: j['tts_sample_rate'] as int? ?? 24000,
        asrAppId: j['asr_app_id'] as String? ?? '',
        asrAccessToken: j['asr_access_token'] as String? ?? '',
        asrCluster: j['asr_cluster'] as String? ?? 'streaming_asr',
      );

  bool get ttsReady => ttsAppId.isNotEmpty && ttsAccessToken.isNotEmpty;
  bool get asrReady => asrAppId.isNotEmpty && asrAccessToken.isNotEmpty;
  bool get llmReady => arkApiKey.isNotEmpty;
}

class SongEntry {
  final String id;
  final String title;
  final String titleCn;
  final String asset;
  final List<String> lyricLines;

  const SongEntry({
    required this.id,
    required this.title,
    required this.titleCn,
    required this.asset,
    this.lyricLines = const [],
  });

  factory SongEntry.fromJson(Map<String, dynamic> j) => SongEntry(
        id: j['id'] as String,
        title: j['title'] as String,
        titleCn: j['title_cn'] as String? ?? '',
        asset: j['asset'] as String,
        lyricLines:
            (j['lyric_lines'] as List? ?? []).map((e) => e as String).toList(),
      );
}

class AppConfig {
  /// 'mock' | 'alibaba' | 'volc'
  final String provider;
  final AlibabaConfig alibaba;
  final VolcConfig volc;
  final String defaultPin;
  final int dailyLimitMinutes;
  final List<SongEntry> songs;

  const AppConfig({
    this.provider = 'mock',
    this.alibaba = const AlibabaConfig(),
    this.volc = const VolcConfig(),
    this.defaultPin = '1234',
    this.dailyLimitMinutes = 30,
    this.songs = const [],
  });

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        provider: j['provider'] as String? ?? 'mock',
        alibaba: AlibabaConfig.fromJson(
            (j['alibaba'] as Map<String, dynamic>?) ?? const {}),
        volc: VolcConfig.fromJson(
            (j['volc'] as Map<String, dynamic>?) ?? const {}),
        defaultPin: ((j['parent'] as Map<String, dynamic>?)?['default_pin']
                as String?) ??
            '1234',
        dailyLimitMinutes: ((j['parent']
                as Map<String, dynamic>?)?['daily_limit_minutes'] as int?) ??
            30,
        songs: (j['songs'] as List? ?? [])
            .map((e) => SongEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static Future<AppConfig> load() async {
    try {
      final raw = await rootBundle.loadString('config/app_config.json');
      return AppConfig.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AppConfig();
    }
  }
}
