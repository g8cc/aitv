import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PIN stored as a fixed-prefix sha256; falls back to the config default until
/// the parent changes it. Failed attempts are rate-limited locally.
class PinStore {
  static const _kPinHash = 'pin_hash_v1';
  static const _kFailedAttempts = 'pin_failed_attempts';
  static const _kLockedUntilMs = 'pin_locked_until_ms';
  static const _maxAttempts = 5;
  static const _lockout = Duration(seconds: 30);
  final SharedPreferences prefs;
  final String defaultPin;

  PinStore(this.prefs, this.defaultPin);

  String _hash(String pin) =>
      sha256.convert(utf8.encode('aitv:$pin')).toString();

  Future<void> setPin(String pin) => prefs.setString(_kPinHash, _hash(pin));

  Future<bool> verify(String pin) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final lockedUntil = prefs.getInt(_kLockedUntilMs) ?? 0;
    if (lockedUntil > now) return false;

    final stored = prefs.getString(_kPinHash);
    if (stored == null) {
      // First use: accept the configured default and adopt it.
      if (pin == defaultPin) {
        await setPin(pin);
        await _clearFailures();
        return true;
      }
      await _recordFailure(now);
      return false;
    }
    if (stored == _hash(pin)) {
      await _clearFailures();
      return true;
    }
    await _recordFailure(now);
    return false;
  }

  Future<void> _recordFailure(int now) async {
    final attempts = (prefs.getInt(_kFailedAttempts) ?? 0) + 1;
    if (attempts >= _maxAttempts) {
      await prefs.setInt(
          _kLockedUntilMs, now + _lockout.inMilliseconds);
      await prefs.remove(_kFailedAttempts);
    } else {
      await prefs.setInt(_kFailedAttempts, attempts);
    }
  }

  Future<void> _clearFailures() async {
    await prefs.remove(_kFailedAttempts);
    await prefs.remove(_kLockedUntilMs);
  }
}
