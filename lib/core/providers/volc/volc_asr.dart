import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../config/app_config.dart';
import '../asr_provider.dart';
import 'volc_frame_codec.dart';

/// Volcengine Doubao streaming ASR over the bidirectional binary protocol.
///
/// NOTE: request/response field paths follow the public protocol doc; verify
/// against the live endpoint during 联调 (final integration test).
class VolcAsrProvider implements AsrProvider {
  final VolcConfig cfg;
  VolcAsrProvider(this.cfg);

  @override
  Future<AsrSession> startSession() async {
    final ch = IOWebSocketChannel.connect(
      Uri.parse(
          'wss://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash'),
      headers: {
        'X-Api-App-Key': cfg.asrAppId,
        'X-Api-Access-Key': cfg.asrAccessToken,
        'X-Api-Resource-Id': 'volc.bigasr.sauc.duration',
        'X-Api-Connect-Id': DateTime.now().microsecondsSinceEpoch.toString(),
      },
    );
    final session = VolcAsrSession(ch);
    session._sendConfig();
    return session;
  }
}

class VolcAsrSession implements AsrSession {
  final WebSocketChannel _ch;
  final _out = StreamController<AsrResult>();
  int _seq = 1;
  bool _configSent = false;

  VolcAsrSession(this._ch) {
    _ch.stream.listen(_onData, onError: (Object e) {
      if (!_out.isClosed) _out.addError(e);
    }, onDone: () {
      if (!_out.isClosed) _out.close();
    });
  }

  void _sendConfig() {
    final frame = encodeFullClientRequest({
      'user': {'uid': 'aitv'},
      'audio': {
        'format': 'pcm',
        'rate': 16000,
        'bits': 16,
        'channel': 1,
        'codec': 'raw',
      },
      'request': {
        'model_name': 'bigmodel',
        'enable_itn': true,
        'result_type': 'full',
      },
    });
    _ch.sink.add(frame);
    _configSent = true;
  }

  void _onData(dynamic data) {
    if (data is! List<int>) return;
    final f = decodeFrame(Uint8List.fromList(data));
    if (f == null) return;
    if (f.type == VolcMsgType.fullServerResponse) {
      final j = decodeJsonPayload(f);
      final text = _extractText(j);
      if (text != null && text.isNotEmpty && !_out.isClosed) {
        _out.add(AsrResult(text, isFinal: f.lastPacket));
      }
    } else if (f.type == VolcMsgType.audioOnlyResponse) {
      // keep-alive ack
    }
  }

  String? _extractText(Map<String, dynamic>? j) {
    if (j == null) return null;
    final r = j['result'];
    if (r is Map && r['text'] is String) return r['text'] as String;
    final p = j['payload_msg'];
    if (p is Map && p['result'] is Map) {
      return (p['result'] as Map)['text'] as String?;
    }
    return null;
  }

  @override
  Stream<AsrResult> get results => _out.stream;

  @override
  void addFrame(Uint8List pcm16) {
    if (!_configSent) return;
    _ch.sink.add(encodeAudioFrame(pcm16, sequence: _seq, last: false));
    _seq++;
  }

  @override
  Future<void> finish() async {
    _ch.sink.add(encodeAudioFrame(Uint8List(0), sequence: _seq, last: true));
  }

  @override
  Future<void> cancel() async {
    await _ch.sink.close();
    if (!_out.isClosed) _out.close();
  }
}
