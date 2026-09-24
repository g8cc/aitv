import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../config/app_config.dart';
import '../asr_provider.dart';

String newTaskId() {
  final r = math.Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// DashScope realtime WebSocket inference (Paraformer ASR).
class AlibabaAsrProvider implements AsrProvider {
  final AlibabaConfig cfg;
  AlibabaAsrProvider(this.cfg);

  @override
  Future<AsrSession> startSession() async {
    final ch = IOWebSocketChannel.connect(
      Uri.parse('wss://dashscope.aliyuncs.com/api-ws/v1/inference'),
      headers: {
        'Authorization': 'Bearer ${cfg.apiKey}',
        'User-Agent': 'aitv/0.1',
      },
    );
    final session = AlibabaAsrSession(ch, cfg);
    session._startTask();
    return session;
  }
}

class AlibabaAsrSession implements AsrSession {
  final WebSocketChannel _ch;
  final AlibabaConfig _cfg;
  final String taskId = newTaskId();
  final _out = StreamController<AsrResult>();
  bool _taskStarted = false;
  final _pending = <Uint8List>[];

  AlibabaAsrSession(this._ch, this._cfg) {
    _ch.stream.listen(_onData, onError: (Object e) {
      if (!_out.isClosed) _out.addError(e);
    }, onDone: () {
      if (!_out.isClosed) _out.close();
    });
  }

  void _startTask() {
    _ch.sink.add(json.encode({
      'header': {
        'action': 'run-task',
        'task_id': taskId,
        'streaming': 'duplex',
      },
      'payload': {
        'task_group': 'audio',
        'task': 'asr',
        'function': 'recognition',
        'model': _cfg.asrModel,
        'parameters': {
          'sample_rate': _cfg.asrSampleRate,
          'format': 'pcm',
        },
        'resources': [],
      },
    }));
  }

  @override
  Stream<AsrResult> get results => _out.stream;

  void _onData(dynamic data) {
    if (data is! String) return;
    late final dynamic j;
    try {
      j = json.decode(data);
    } catch (_) {
      return;
    }
    final event = (j['header'] as Map?)?['event'] as String?;
    switch (event) {
      case 'task-started':
        _taskStarted = true;
        for (final f in _pending) {
          _ch.sink.add(f);
        }
        _pending.clear();
        break;
      case 'result-generated':
        final output = ((j['payload'] as Map?)?['output'] as Map?) ?? const {};
        final sentence = output['sentence'] as Map?;
        final text = sentence?['text'] as String? ?? '';
        final isEnd = sentence?['sentence_end'] == true;
        if (text.isNotEmpty && !_out.isClosed) {
          _out.add(AsrResult(text, isFinal: isEnd));
        }
        break;
      case 'task-finished':
      case 'task-failed':
        if (!_out.isClosed) _out.close();
        break;
    }
  }

  @override
  void addFrame(Uint8List pcm16) {
    if (_taskStarted) {
      _ch.sink.add(pcm16);
    } else {
      _pending.add(pcm16);
    }
  }

  @override
  Future<void> finish() async {
    if (_taskStarted) {
      _ch.sink.add(json.encode({
        'header': {
          'action': 'finish-task',
          'task_id': taskId,
          'streaming': 'duplex',
        },
        'payload': {'input': {}},
      }));
    } else {
      await _ch.sink.close();
      if (!_out.isClosed) _out.close();
    }
  }

  @override
  Future<void> cancel() async {
    await _ch.sink.close();
    if (!_out.isClosed) _out.close();
  }
}
