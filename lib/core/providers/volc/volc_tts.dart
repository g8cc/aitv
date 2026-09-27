import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../config/app_config.dart';
import '../tts_provider.dart';

/// Volcengine Doubao TTS over the HTTP V1 interface (one-shot synthesis,
/// response audio is base64 wav). Simplest reliable integration; swap to
/// the bidirectional WebSocket later if latency needs to drop below ~1s.
class VolcTtsFetcher implements TtsFetcher {
  final VolcConfig cfg;
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
  ));
  CancelToken? _activeCancel;

  VolcTtsFetcher(this.cfg);

  @override
  Future<Uint8List> fetchWav(String text) async {
    final cancel = CancelToken();
    _activeCancel = cancel;
    try {
      final resp = await _dio.post<dynamic>(
        'https://openspeech.bytedance.com/api/v1/tts',
        data: {
          'app': {
            'appid': cfg.ttsAppId,
            'token': cfg.ttsAccessToken,
            'cluster': cfg.ttsCluster,
          },
          'user': {'user_id': 'aitv'},
          'audio': {
            'voice': cfg.ttsVoiceType,
            'encoding': 'wav',
            'sample_rate': cfg.ttsSampleRate,
            'speech_rate': 0,
            'volume': 0,
            'language': 'zh-CN',
          },
          'request': {
            'reqid': 'aitv-${DateTime.now().millisecondsSinceEpoch}',
            'text': text,
            'operation': 'full',
            'model': 'speech-01-turbo',
          },
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer;${cfg.ttsAccessToken}',
            'Content-Type': 'application/json',
          },
        ),
        cancelToken: cancel,
      );
      final data = resp.data is String
          ? json.decode(resp.data as String)
          : resp.data as Map<String, dynamic>;
      final code = data['code'];
      if (code != 3000) {
        throw StateError('volc tts error $code: ${data['message']}');
      }
      return base64.decode(data['data'] as String);
    } finally {
      if (identical(_activeCancel, cancel)) _activeCancel = null;
    }
  }

  @override
  Future<void> cancel() async => _activeCancel?.cancel('tts cancelled');

  @override
  Future<void> dispose() async {
    await cancel();
    _dio.close(force: true);
  }
}
