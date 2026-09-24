import 'dart:async';
import 'dart:typed_data';

/// One recognized utterance. [partial] streams intermediate results; the
/// final one has isFinal = true.
class AsrResult {
  final String text;
  final bool isFinal;
  AsrResult(this.text, {this.isFinal = false});
}

/// A streaming recognition session. Feed PCM16 frames via [addFrame]; results
/// arrive on [results]. Call [finish] at speech-end to flush the last final.
abstract class AsrSession {
  Stream<AsrResult> get results;
  void addFrame(Uint8List pcm16);
  Future<void> finish();
  Future<void> cancel();
}

abstract class AsrProvider {
  Future<AsrSession> startSession();
}

/// Mock ASR emits nothing from audio; the app injects text directly via
/// [submitTypedText] (a hidden keyboard fallback used in demo/testing).
class MockAsrProvider implements AsrProvider {
  MockAsrSession? _current;

  void submitTypedText(String text) {
    _current?.injectText(text);
  }

  @override
  Future<AsrSession> startSession() async {
    final s = MockAsrSession();
    _current = s;
    return s;
  }
}

class MockAsrSession implements AsrSession {
  final _out = StreamController<AsrResult>();

  @override
  Stream<AsrResult> get results => _out.stream;

  @override
  void addFrame(Uint8List pcm16) {}

  void injectText(String text) {
    if (!_out.isClosed) _out.add(AsrResult(text, isFinal: true));
  }

  @override
  Future<void> finish() async {
    await _out.close();
  }

  @override
  Future<void> cancel() => finish();
}
