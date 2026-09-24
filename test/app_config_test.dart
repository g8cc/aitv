import 'dart:convert';
import 'dart:io';

import 'package:aitv/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shipped config', () {
    late AppConfig cfg;

    setUpAll(() {
      final raw = File('config/app_config.json').readAsStringSync();
      cfg = AppConfig.fromJson(json.decode(raw) as Map<String, dynamic>);
    });

    test('defaults to the offline mock provider', () {
      expect(cfg.provider, 'mock');
    });

    test('ships no API keys or secrets', () {
      expect(cfg.alibaba.apiKey, isEmpty);
      expect(cfg.volc.arkApiKey, isEmpty);
      expect(cfg.volc.ttsAppId, isEmpty);
      expect(cfg.volc.ttsAccessToken, isEmpty);
      expect(cfg.volc.asrAppId, isEmpty);
      expect(cfg.volc.asrAccessToken, isEmpty);
      expect(cfg.alibaba.ready, isFalse);
      expect(cfg.volc.ttsReady, isFalse);
      expect(cfg.volc.asrReady, isFalse);
      expect(cfg.volc.llmReady, isFalse);
    });

    test('declares usable model / voice ids for both vendors', () {
      expect(cfg.alibaba.llmModel, isNotEmpty);
      expect(cfg.alibaba.asrModel, isNotEmpty);
      expect(cfg.alibaba.ttsModel, isNotEmpty);
      expect(cfg.alibaba.ttsVoice, isNotEmpty);
      expect(cfg.volc.llmModel, isNotEmpty);
      expect(cfg.volc.ttsCluster, isNotEmpty);
    });

    test('parent defaults are sane', () {
      expect(RegExp(r'^\d{4}$').hasMatch(cfg.defaultPin), isTrue);
      expect(cfg.dailyLimitMinutes, inInclusiveRange(5, 240));
    });

    test('every configured song points at a bundled asset', () {
      expect(cfg.songs, isNotEmpty);
      for (final s in cfg.songs) {
        expect(s.id, isNotEmpty);
        expect(File(s.asset).existsSync(), isTrue,
            reason: 'missing ${s.asset}');
      }
    });
  });

  group('AppConfig.fromJson', () {
    test('empty json yields all-default values', () {
      final c = AppConfig.fromJson(const {});
      expect(c.provider, 'mock');
      expect(c.defaultPin, '1234');
      expect(c.dailyLimitMinutes, 30);
      expect(c.songs, isEmpty);
    });

    test('partial vendor blocks keep their sibling defaults', () {
      final c = AppConfig.fromJson({
        'provider': 'alibaba',
        'alibaba': {'api_key': 'sk-test'},
        'parent': {'daily_limit_minutes': 15},
      });
      expect(c.provider, 'alibaba');
      expect(c.alibaba.ready, isTrue);
      expect(c.alibaba.ttsVoice, 'longxiaochun');
      expect(c.volc.arkApiKey, isEmpty);
      expect(c.dailyLimitMinutes, 15);
      expect(c.defaultPin, '1234');
    });
  });
}
