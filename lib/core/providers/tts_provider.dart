import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../audio/wav_util.dart';

/// Text -> speech + live amplitude envelope (0..1 at ~30 Hz) used for
/// lip-sync. `speak` resolves when playback finished or was stopped.
abstract class TtsProvider {
  Stream<double> get amplitudes;
  Future<void> speak(String text);
  Future<void> stop();
  Future<void> dispose() async {}
}

/// Produces RIFF wav bytes for a text (cloud providers implement this).
abstract class TtsFetcher {
  Future<Uint8List> fetchWav(String text);
  Future<void> dispose() async {}
}

/// Synthesizes via [TtsFetcher], plays with just_audio, and replays the
/// decoded wav's envelope in sync with playback position.
class CloudTtsProvider implements TtsProvider {
  final TtsFetcher fetcher;
  final AudioPlayer _player = AudioPlayer();
  final _amplitudes = StreamController<double>.broadcast();
  Timer? _envTimer;
  List<double> _envelope = const [];
  Completer<void>? _done;
  StreamSubscription<ProcessingState>? _completeSub;

  CloudTtsProvider(this.fetcher);

  @override
  Stream<double> get amplitudes => _amplitudes.stream;

  @override
  Future<void> speak(String text) async {
    final wav = await fetcher.fetchWav(text);
    final pcm = WavUtil.extractPcm16(wav);
    if (pcm != null) {
      final rate = ByteData.sublistView(wav).getUint32(24, Endian.little);
      _envelope = WavUtil.envelope(pcm, rate, windowMs: 33);
    } else {
      _envelope = const [];
    }
    final dir = await getTemporaryDirectory();
    final file =
        File('${dir.path}/tts_${DateTime.now().microsecondsSinceEpoch}.wav');
    await file.writeAsBytes(wav);
    _done = Completer<void>();
    await _player.setFilePath(file.path);
    _completeSub = _player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed &&
          _done != null &&
          !_done!.isCompleted) {
        _done!.complete();
      }
    });
    _startEnvelope();
    await _player.play();
    await _done!.future;
    _stopEnvelope();
    await _completeSub?.cancel();
    unawaited(file.delete().catchError((e) => file));
  }

  void _startEnvelope() {
    _stopEnvelope();
    if (_envelope.isEmpty) return;
    _envTimer = Timer.periodic(const Duration(milliseconds: 33), (t) {
      final idx = (_player.position.inMilliseconds / 33).round();
      final v = idx < _envelope.length ? _envelope[idx] : 0.0;
      if (!_amplitudes.isClosed) {
        _amplitudes.add(math.min(1.0, v * 1.8));
      }
    });
  }

  void _stopEnvelope() {
    _envTimer?.cancel();
    _envTimer = null;
    if (!_amplitudes.isClosed) _amplitudes.add(0);
  }

  @override
  Future<void> stop() async {
    _stopEnvelope();
    if (_done != null && !_done!.isCompleted) _done!.complete();
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    _stopEnvelope();
    await _completeSub?.cancel();
    await _player.dispose();
    await _amplitudes.close();
    await fetcher.dispose();
  }
}

/// Mock TTS using the platform voice; emits a speech-like pseudo envelope
/// so the character still lip-moves without any API key.
class MockTtsProvider implements TtsProvider {
  final FlutterTts tts = FlutterTts();
  final _amplitudes = StreamController<double>.broadcast();
  final math.Random _rnd = math.Random();
  Timer? _fakeTimer;

  MockTtsProvider() {
    tts.setLanguage('en-US');
    tts.setSpeechRate(0.42);
    tts.setPitch(1.15);
  }

  @override
  Stream<double> get amplitudes => _amplitudes.stream;

  @override
  Future<void> speak(String text) async {
    final done = Completer<void>();
    tts.setCompletionHandler(() {
      if (!done.isCompleted) done.complete();
    });
    tts.setErrorHandler((e) {
      if (!done.isCompleted) done.completeError(e);
    });
    _startFakeEnvelope(text);
    await tts.speak(text);
    await done.future.timeout(const Duration(minutes: 3), onTimeout: () {});
    _stopFakeEnvelope();
  }

  void _startFakeEnvelope(String text) {
    _fakeTimer?.cancel();
    _fakeTimer = Timer.periodic(const Duration(milliseconds: 60), (t) {
      final wps =
          (text.split(RegExp(r'\s+')).length / 2.2).clamp(1.5, 5.0).toDouble();
      final phase = (t.tick * 0.06 * wps) % 1.0;
      final env = math.sin(phase * math.pi);
      if (!_amplitudes.isClosed) {
        _amplitudes
            .add((env * (0.55 + _rnd.nextDouble() * 0.4)).clamp(0.0, 1.0));
      }
    });
  }

  void _stopFakeEnvelope() {
    _fakeTimer?.cancel();
    _fakeTimer = null;
    if (!_amplitudes.isClosed) _amplitudes.add(0);
  }

  @override
  Future<void> stop() async {
    _stopFakeEnvelope();
    await tts.stop();
  }

  @override
  Future<void> dispose() async {
    _fakeTimer?.cancel();
    await tts.stop();
    await _amplitudes.close();
  }
}
