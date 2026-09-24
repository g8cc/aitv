import 'dart:typed_data';

import 'package:aitv/core/audio/pcm_util.dart';
import 'package:aitv/core/audio/wav_util.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List frame(double amplitude, {int samples = 480}) =>
    PcmUtil.pcm16BytesFromDoubles(List.filled(samples, amplitude));

void main() {
  group('PcmUtil', () {
    test('rms and peak of a constant tone', () {
      final f = frame(0.5);
      expect(PcmUtil.rms(f), closeTo(0.5, 0.001));
      expect(PcmUtil.peak(f), closeTo(0.5, 0.001));
    });

    test('silence is zero', () {
      expect(PcmUtil.rms(frame(0)), 0);
      expect(PcmUtil.peak(frame(0)), 0);
    });

    test('empty or runt chunk is safe', () {
      expect(PcmUtil.rms(Uint8List(0)), 0);
      expect(PcmUtil.peak(Uint8List(1)), 0);
    });
  });

  group('WavUtil', () {
    test('wrap then extract round-trips samples', () {
      final samples = List<int>.generate(1000, (i) => (i * 37) % 5000 - 2500);
      final wav = WavUtil.wrapPcm16(samples, 16000);
      expect(wav.length, 44 + 2000);
      final back = WavUtil.extractPcm16(wav);
      expect(back, isNotNull);
      expect(back!.length, samples.length);
      for (var i = 0; i < samples.length; i++) {
        expect(back[i], samples[i]);
      }
    });

    test('non-wav bytes return null', () {
      expect(WavUtil.extractPcm16(List<int>.filled(64, 0)), isNull);
    });

    test('envelope has one value per window and tracks loudness', () {
      final loud = Int16List.fromList(List.filled(1600, 20000));
      final env = WavUtil.envelope(loud, 16000, windowMs: 33);
      expect(env.length, (1600 / 528).ceil());
      expect(env.first, closeTo(20000 / 32768, 0.001));

      final silent = WavUtil.envelope(Int16List(1600), 16000);
      expect(silent.every((v) => v == 0), isTrue);
    });
  });
}
