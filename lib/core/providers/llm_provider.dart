import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

class ChatMessage {
  final String role; // system | user | assistant
  final String content;
  ChatMessage(this.role, this.content);

  Map<String, String> toJson() => {'role': role, 'content': content};
}

/// Streams assistant reply tokens for one conversation turn.
abstract class LlmProvider {
  Stream<String> streamChat(List<ChatMessage> messages);

  /// Cancels the current request when the UI abandons a turn.
  Future<void> cancel() async {}

  Future<String> complete(List<ChatMessage> messages) async {
    final sb = StringBuffer();
    await for (final t in streamChat(messages)) {
      sb.write(t);
    }
    return sb.toString();
  }
}

/// OpenAI-compatible /chat/completions endpoint (works for DashScope
/// compatible-mode and Volc Ark).
class OpenAiCompatLlm implements LlmProvider {
  final String baseUrl;
  final String apiKey;
  final String model;
  final Dio _dio;
  CancelToken? _activeCancel;

  OpenAiCompatLlm({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 60),
            ));

  @override
  Future<String> complete(List<ChatMessage> messages) async {
    final cancel = CancelToken();
    _activeCancel = cancel;
    try {
      final resp = await _dio.post<dynamic>(
        '$baseUrl/chat/completions',
        data: {
          'model': model,
          'messages': messages.map((m) => m.toJson()).toList(),
          'stream': false,
          'temperature': 0.7,
          'max_tokens': 300,
        },
        options: Options(headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        }),
        cancelToken: cancel,
      );
      final data = resp.data;
      final map = data is String ? json.decode(data) : data;
      return (((map['choices'] as List).first['message'] as Map)['content']
              as String?) ??
          '';
    } finally {
      if (identical(_activeCancel, cancel)) _activeCancel = null;
    }
  }

  @override
  Stream<String> streamChat(List<ChatMessage> messages) async* {
    final cancel = CancelToken();
    _activeCancel = cancel;
    try {
      final resp = await _dio.post<ResponseBody>(
        '$baseUrl/chat/completions',
        data: {
          'model': model,
          'messages': messages.map((m) => m.toJson()).toList(),
          'stream': true,
          'temperature': 0.7,
          'max_tokens': 300,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'Accept': 'text/event-stream',
          },
          responseType: ResponseType.stream,
        ),
        cancelToken: cancel,
      );
      String pending = '';
      await for (final chunk in utf8.decoder.bind(resp.data!.stream)) {
        pending += chunk;
        final lines = pending.split('\n');
        pending = lines.removeLast();
        for (final line in lines) {
          final t = _parseSseLine(line);
          if (t != null && t.isNotEmpty) yield t;
        }
      }
      final t = _parseSseLine(pending);
      if (t != null && t.isNotEmpty) yield t;
    } finally {
      if (identical(_activeCancel, cancel)) _activeCancel = null;
    }
  }

  @override
  Future<void> cancel() async => _activeCancel?.cancel('llm cancelled');

  static String? _parseSseLine(String line) {
    final s = line.trim();
    if (!s.startsWith('data:')) return null;
    final payload = s.substring(5).trim();
    if (payload.isEmpty || payload == '[DONE]') return null;
    try {
      final j = json.decode(payload);
      final choices = j['choices'] as List?;
      if (choices == null || choices.isEmpty) return null;
      final delta = choices[0]['delta'] as Map?;
      return delta?['content'] as String?;
    } catch (_) {
      return null;
    }
  }
}
