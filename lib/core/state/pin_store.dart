import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PIN stored as salted sha256; falls back to the config default until the
/// parent changes it.
class PinStore {
  static const _kPinHash = 'pin_hash_v1';
  final SharedPreferences prefs;
  final String defaultPin;

  PinStore(this.prefs, this.defaultPin);

  String _hash(String pin) =>
      sha256.convert(utf8.encode('aitv:$pin')).toString();

  Future<void> setPin(String pin) => prefs.setString(_kPinHash, _hash(pin));

  Future<bool> verify(String pin) async {
    final stored = prefs.getString(_kPinHash);
    if (stored == null) {
      // First use: accept the configured default and adopt it.
      if (pin == defaultPin) {
        await setPin(pin);
        return true;
      }
      return false;
    }
    return stored == _hash(pin);
  }
}
