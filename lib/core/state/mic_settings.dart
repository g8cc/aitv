import 'package:shared_preferences/shared_preferences.dart';

/// Which microphone the app records from, chosen in the parent self-check page.
///
/// Index -1 means "whatever the system picked", served by the `record` plugin.
/// Any other index asks the native channel to prefer that input device, which
/// is how a TV with a silent built-in default and a working USB mic gets going.
class MicSettings {
  static const _kIndex = 'mic_input_index';
  static const _kName = 'mic_input_name';

  final SharedPreferences _prefs;
  MicSettings(this._prefs);

  int get inputIndex => _prefs.getInt(_kIndex) ?? -1;
  String? get inputName => _prefs.getString(_kName);
  bool get usesNativeDevice => inputIndex >= 0;

  Future<void> setDevice({required int index, String? name}) async {
    await _prefs.setInt(_kIndex, index);
    if (name == null || name.isEmpty) {
      await _prefs.remove(_kName);
    } else {
      await _prefs.setString(_kName, name);
    }
  }

  Future<void> useSystemDefault() async {
    await _prefs.setInt(_kIndex, -1);
    await _prefs.remove(_kName);
  }
}
