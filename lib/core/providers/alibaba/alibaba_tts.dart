import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import '../../config/app_config.dart';
import '../../audio/wav_util.dart';
import '../tts_provider.dart';
import 'alibaba_asr.dart' show newTaskId;

/// DashScope CosyVoice realtime TTS: run-task -> binary audio frames ->
/// task-finished. Collects pcm16 and wraps as wav for lip-sync playback.
class AlibabaTtsFetcher implements TtsFetcher {
  final AlibabaConfig cfg;
  IOWebSocketChannel? _activeChannel;
  Completer<void>? _activeDone;
  bool _cancelRequested = false;

  AlibabaTtsFetcher(this.cfg);

  @override
  Future<Uint8List> fetchWav(String text) async {
    final ch = IOWebSocketChannel.connect(
      Uri.parse('wss://dashscope.aliyuncs.com/api-ws/v1/inference'),
      headers: {'Authorization': 'Bearer ${cfg.apiKey}'},
      connectTimeout: const Duration(seconds: 10),
      pingInterval: const Duration(seconds: 20),
    );
    final taskId = newTaskId();
    final pcm = BytesBuilder(copy: false);
    final done = Completer<void>();
    _activeChannel = ch;
    _activeDone = done;
    _cancelRequested = false;

    void handle(dynamic data) {
      if (_cancelRequested) return;
      if (data is List<int>) {
        // Binary frame: may carry a small text header before audio; treat
        // pure binary payloads (audio chunks) directly.
        pcm.add(data);
        return;
      }
      if (data is! String) return;
      Map j;
      try {
        j = json.decode(data);
      } catch (_) {
        return;
      }
      final event = (j['header'] as Map?)?['event'] as String?;
      if (event == 'task-finished') {
        if (!done.isCompleted) done.complete();
      } else if (event == 'task-failed') {
        if (!done.isCompleted) {
          done.completeError(StateError('Alibaba TTS task failed'));
        }
      } else if (event == 'task-started') {
        ch.sink.add(json.encode({
          'header': {
            'action': 'continue-task',
            'task_id': taskId,
            'streaming': 'duplex',
          },
          'payload': {
            'input': {'text': text},
          },
        }));
        ch.sink.add(json.encode({
          'header': {
            'action': 'finish-task',
            'task_id': taskId,
            'streaming': 'duplex',
          },
          'payload': {'input': {}},
        }));
      }
    }

    try {
      ch.stream.listen(
        handle,
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );

      ch.sink.add(json.encode({
        'header': {
          'action': 'run-task',
          'task_id': taskId,
          'streaming': 'duplex',
        },
        'payload': {
          'task_group': 'audio',
          'task': 'tts',
          'function': 'SpeechSynthesizer',
          'model': cfg.ttsModel,
          'parameters': {
            'text_type': 'PlainText',
            'voice': cfg.ttsVoice,
            'format': 'pcm',
            'sample_rate': cfg.ttsSampleRate,
          },
          'input': {},
        },
      }));

      await done.future.timeout(const Duration(seconds: 30));
    } finally {
      // Timeout or error must not leak the WebSocket: close it on every path.
      try {
        await ch.sink.close();
      } catch (_) {}
      if (identical(_activeChannel, ch)) _activeChannel = null;
      if (identical(_activeDone, done)) _activeDone = null;
    }
    return Uint8List.fromList(
        WavUtil.wrapPcm16Bytes(pcm.toBytes(), cfg.ttsSampleRate));
  }

  @override
  Future<void> cancel() async {
    _cancelRequested = true;
    final done = _activeDone;
    if (done != null && !done.isCompleted) {
      done.completeError(StateError('Alibaba TTS cancelled'));
    }
    final channel = _activeChannel;
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {}
    }
  }

  @override
  Future<void> dispose() async => cancel();
}
