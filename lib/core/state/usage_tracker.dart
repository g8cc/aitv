import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// Daily usage meter + parental lock state.
class UsageTracker {
  static const _kDate = 'usage_date';
  static const _kSeconds = 'usage_seconds';
  static const _kLimitMin = 'daily_limit_min';
  static const _kConsent = 'mic_consent';

  final SharedPreferences _prefs;
  final int defaultLimitMinutes;
  String? _loadedDate;
  bool _paused = false;

  UsageTracker(this._prefs, {this.defaultLimitMinutes = 30}) {
    _rollover();
  }

  int _seconds = 0;
  int get usedSeconds => _seconds;
  bool get isPaused => _paused;
  int get limitMinutes => _prefs.getInt(_kLimitMin) ?? defaultLimitMinutes;
  set limitMinutes(int m) => _prefs.setInt(_kLimitMin, m);

  bool get consentGiven => _prefs.getBool(_kConsent) ?? false;
  set consentGiven(bool v) => _prefs.setBool(_kConsent, v);

  bool get isLocked {
    _rolloverIfNeeded();
    return _seconds >= limitMinutes * 60;
  }

  /// Rolls over at midnight; resets counter on a new day.
  void _rollover() {
    final today = _today();
    if (_prefs.getString(_kDate) != today) {
      _prefs.setString(_kDate, today);
      _prefs.setInt(_kSeconds, 0);
    }
    _seconds = _prefs.getInt(_kSeconds) ?? 0;
    _loadedDate = today;
  }

  void _rolloverIfNeeded() {
    if (_loadedDate != _today()) _rollover();
  }

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  void tickSecond() {
    if (_paused) return;
    _rolloverIfNeeded();
    if (isLocked) return;
    _seconds++;
    unawaited(_prefs.setInt(_kSeconds, _seconds));
  }

  void pause() => _paused = true;

  void resume() => _paused = false;

  int remainingSeconds() {
    _rolloverIfNeeded();
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
