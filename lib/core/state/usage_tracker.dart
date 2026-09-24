import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Daily usage meter + parental lock state.
class UsageTracker {
  static const _kDate = 'usage_date';
  static const _kSeconds = 'usage_seconds';
  static const _kLimitMin = 'daily_limit_min';
  static const _kConsent = 'mic_consent';

  final SharedPreferences _prefs;
  UsageTracker(this._prefs);

  int _seconds = 0;
  int get usedSeconds => _seconds;
  int get limitMinutes => _prefs.getInt(_kLimitMin) ?? 30;
  set limitMinutes(int m) => _prefs.setInt(_kLimitMin, m);

  bool get consentGiven => _prefs.getBool(_kConsent) ?? false;
  set consentGiven(bool v) => _prefs.setBool(_kConsent, v);

  bool get isLocked => _seconds >= limitMinutes * 60;

  /// Rolls over at midnight; resets counter on a new day.
  void _rollover() {
    final today = _today();
    if (_prefs.getString(_kDate) != today) {
      _prefs.setString(_kDate, today);
      _prefs.setInt(_kSeconds, 0);
    }
    _seconds = _prefs.getInt(_kSeconds) ?? 0;
  }

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  void tickSecond() {
    if (isLocked) return;
    _seconds++;
    unawaited(_prefs.setInt(_kSeconds, _seconds));
  }

  int remainingSeconds() {
    _rollover();
    final left = limitMinutes * 60 - _seconds;
    return left < 0 ? 0 : left;
  }

  static Future<UsageTracker> load() async {
    final prefs = await SharedPreferences.getInstance();
    final t = UsageTracker(prefs);
    t._rollover();
    return t;
  }
}
