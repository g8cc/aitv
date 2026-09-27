import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Playback of the preloaded nursery-rhyme files. Kept behind an interface so
/// the song flow can be exercised without the audio plugin.
abstract class SongPlayer {
  /// Load [asset] and start playing; throws when it cannot be played.
  /// [onFinished] fires once the track reaches its end.
  Future<void> play(String asset, {required void Function() onFinished});

  Future<void> stop();

  Future<void> dispose();
}

class JustAudioSongPlayer implements SongPlayer {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<ProcessingState>? _doneSub;
  int _generation = 0;

  @override
  Future<void> play(String asset, {required void Function() onFinished}) async {
    final generation = ++_generation;
    await _doneSub?.cancel();
    await _player.setAsset(asset);
    if (generation != _generation) return;
    var finished = false;
    _doneSub = _player.processingStateStream.listen((s) {
      if (s == ProcessingState.completed && !finished) {
        finished = true;
        onFinished();
      }
    });
    try {
      await _player.play();
    } finally {
      if (generation == _generation) {
        await _doneSub?.cancel();
        _doneSub = null;
      }
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    await _doneSub?.cancel();
    _doneSub = null;
    try {
      await _player.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}
