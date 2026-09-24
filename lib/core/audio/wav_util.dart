import 'dart:math' as math;
import 'dart:typed_data';

/// Minimal RIFF/WAVE helpers for 16-bit PCM.
class WavUtil {
  /// Extract mono pcm16 samples from a wav file's bytes.
  /// Returns null if not a parseable wav.
  static Int16List? extractPcm16(List<int> bytes) {
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    if (bytes.length < 44) return null;
    if (String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      return null;
    }
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = bd.getUint32(offset + 4, Endian.little);
      final dataStart = offset + 8;
      if (id == 'data') {
        final n = size ~/ 2;
        final out = Int16List(n);
        for (var i = 0; i < n; i++) {
          out[i] = bd.getInt16(dataStart + i * 2, Endian.little);
        }
        return out;
      }
      offset = dataStart + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  /// Wrap pcm16 samples into a mono RIFF wav.
  static Uint8List wrapPcm16(List<int> pcm, int sampleRate) {
    final dataLen = pcm.length * 2;
    final out = Uint8List(44 + dataLen);
    final bd = ByteData.sublistView(out);
    void put(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        out[o + i] = s.codeUnitAt(i);
      }
    }

    put(0, 'RIFF');
    bd.setUint32(4, 36 + dataLen, Endian.little);
    put(8, 'WAVE');
    put(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, 1, Endian.little); // mono
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, sampleRate * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    put(36, 'data');
    bd.setUint32(40, dataLen, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      bd.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return out;
  }

  /// RMS envelope of pcm16 samples, one value per [windowMs] window.
  static List<double> envelope(Int16List samples, int sampleRate,
      {int windowMs = 33}) {
    final win = (sampleRate * windowMs / 1000).round();
    final out = <double>[];
    for (var start = 0; start < samples.length; start += win) {
      final end = (start + win) > samples.length ? samples.length : start + win;
      double sum = 0;
      for (var i = start; i < end; i++) {
        sum += samples[i] * samples[i];
      }
      final n = (end - start).clamp(1, 1 << 30);
      out.add(math.sqrt(sum / n) / 32768.0);
    }
    return out;
  }
}
