import 'dart:math' as math;
import 'dart:typed_data';

/// Utilities for 16-bit little-endian PCM streams.
class PcmUtil {
  /// Root-mean-square amplitude of a pcm16le chunk, normalized 0..1.
  static double rms(Uint8List bytes) {
    if (bytes.length < 2) return 0;
    final bd = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      sum += s * s;
    }
    return math.sqrt(sum / n) / 32768.0;
  }

  /// Peak absolute sample, normalized 0..1.
  static double peak(Uint8List bytes) {
    if (bytes.length < 2) return 0;
    final bd = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    double p = 0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little).abs();
      if (s > p) p = s.toDouble();
    }
    return p / 32768.0;
  }

  static Uint8List pcm16BytesFromDoubles(List<double> samples) {
    final out = Uint8List(samples.length * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < samples.length; i++) {
      final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
      bd.setInt16(i * 2, v, Endian.little);
    }
    return out;
  }
}
