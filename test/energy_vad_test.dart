import 'dart:typed_data';

import 'package:aitv/core/audio/energy_vad.dart';
import 'package:aitv/core/audio/pcm_util.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List frame(double amplitude, {int samples = 480}) =>
    PcmUtil.pcm16BytesFromDoubles(List.filled(samples, amplitude));

void main() {
  group('EnergyVad', () {
    late EnergyVad vad;
    late List<VadPhase> phases;

    setUp(() {
      vad = EnergyVad();
      phases = [];
      vad.events.listen((e) => phases.add(e.phase));
    });

    tearDown(() async => vad.dispose());

    Future<void> settle() => pumpEventQueue();

    test('quiet room alone never triggers', () async {
      for (var i = 0; i < 200; i++) {
        vad.feedFrame(frame(0.004));
      }
      await settle();
      expect(phases, isEmpty);
      expect(vad.isSpeaking, isFalse);
    });

    test('speech needs startFrames loud frames before it triggers', () async {
      for (var i = 0; i < 40; i++) {
        vad.feedFrame(frame(0));
      }
      vad.feedFrame(frame(0.4));
      vad.feedFrame(frame(0.4));
      await settle();
      expect(phases, isEmpty, reason: 'two loud frames are not enough');
      vad.feedFrame(frame(0.4));
      await settle();
      expect(phases, [VadPhase.start]);
      expect(vad.isSpeaking, isTrue);
    });

    test('one loud frame inside speech does not end the utterance', () async {
      for (var i = 0; i < 40; i++) {
        vad.feedFrame(frame(0));
      }
      for (var i = 0; i < 5; i++) {
        vad.feedFrame(frame(0.4));
      }
      await settle();
      expect(phases, [VadPhase.start]);

      vad.feedFrame(frame(0));
      vad.feedFrame(frame(0));
      await settle();
      expect(phases, [VadPhase.start], reason: 'hangover not elapsed');

      for (var i = 0; i < 15; i++) {
        vad.feedFrame(frame(0));
      }
      await settle();
      expect(phases, [VadPhase.start, VadPhase.end]);
      expect(vad.isSpeaking, isFalse);
    });

    test('a long utterance is force-cut at maxUtteranceFrames', () async {
      final v = EnergyVad(maxUtteranceFrames: 20);
      final seen = <VadPhase>[];
      v.events.listen((e) => seen.add(e.phase));
      for (var i = 0; i < 5; i++) {
        v.feedFrame(frame(0));
      }
      for (var i = 0; i < 40; i++) {
        v.feedFrame(frame(0.4));
      }
      await settle();
      expect(seen, contains(VadPhase.end));
      await v.dispose();
    });
  });
}
