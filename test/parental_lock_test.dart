import 'package:aitv/core/state/pin_store.dart';
import 'package:aitv/core/state/usage_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('UsageTracker', () {
    test('counts down from the daily limit and locks at zero', () async {
      SharedPreferences.setMockInitialValues({'daily_limit_min': 1});
      final t = await UsageTracker.load();
      expect(t.limitMinutes, 1);
      expect(t.isLocked, isFalse);
      expect(t.remainingSeconds(), 60);

      for (var i = 0; i < 60; i++) {
        t.tickSecond();
      }
      expect(t.usedSeconds, 60);
      expect(t.remainingSeconds(), 0);
      expect(t.isLocked, isTrue);

      // Locked time no longer accumulates.
      t.tickSecond();
      expect(t.usedSeconds, 60);
    });

    test('raising the limit unlocks the session', () async {
      SharedPreferences.setMockInitialValues({'daily_limit_min': 1});
      final t = await UsageTracker.load();
      for (var i = 0; i < 61; i++) {
        t.tickSecond();
      }
      expect(t.isLocked, isTrue);
      t.limitMinutes = 30;
      expect(t.limitMinutes, 30);
      expect(t.isLocked, isFalse);
    });

    test('a new day resets the counter', () async {
      SharedPreferences.setMockInitialValues({
        'usage_date': '2000-1-1',
        'usage_seconds': 900,
        'daily_limit_min': 1,
      });
      final t = await UsageTracker.load();
      expect(t.usedSeconds, 0);
      expect(t.isLocked, isFalse);
    });

    test('mic consent is off until a parent grants it', () async {
      SharedPreferences.setMockInitialValues({});
      final t = await UsageTracker.load();
      expect(t.consentGiven, isFalse);
      t.consentGiven = true;
      expect((await SharedPreferences.getInstance()).getBool('mic_consent'),
          isTrue);
    });
  });

  group('PinStore', () {
    test('first use adopts the configured default pin', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = PinStore(prefs, '1234');
      expect(await store.verify('0000'), isFalse);
      expect(await store.verify('1234'), isTrue);
      expect(prefs.getString('pin_hash_v1'), isNotNull);
    });

    test('changed pin replaces the default', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = PinStore(prefs, '1234');
      await store.verify('1234');
      await store.setPin('9876');
      expect(await store.verify('1234'), isFalse);
      expect(await store.verify('9876'), isTrue);
    });

    test('pin is never stored in clear text', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await PinStore(prefs, '1234').setPin('4321');
      final stored = prefs.getString('pin_hash_v1')!;
      expect(stored.contains('4321'), isFalse);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(stored), isTrue);
    });
  });
}
