import 'dart:async';
import 'dart:convert';

import 'package:flutter/painting.dart' show Color;
import 'package:webview_flutter/webview_flutter.dart';

/// The part of the on-screen character the conversation loop drives. Kept
/// separate from the WebView implementation so the voice pipeline can be
/// exercised without a rendering surface.
abstract class CharacterDriver {
  Future<void> get ready;
  void setLip(double value);
  void setSpeaking(bool on);
  void playAction(String name);
  void mood(String mood);
}

/// Owns the Live2D WebView and the Dart<->JS message protocol defined in
/// assets/live2d/viewer.html (`window.ktv.onMessage`).
class CharacterController implements CharacterDriver {
  final WebViewController controller;
  final _ready = Completer<void>();

  bool _jsReady = false;
  final _queue = <Map<String, dynamic>>[];

  CharacterController() : controller = WebViewController() {
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel('KtvBridge', onMessageReceived: _onBridge)
      ..loadFlutterAsset('assets/live2d/viewer.html');
  }

  @override
  Future<void> get ready => _ready.future;

  void _onBridge(JavaScriptMessage msg) {
    try {
      final j = json.decode(msg.message) as Map<String, dynamic>;
      if (j['event'] == 'ready') {
        _jsReady = true;
        for (final m in _queue) {
          _send(m);
        }
        _queue.clear();
        if (!_ready.isCompleted) _ready.complete();
      }
    } catch (_) {}
  }

  void _send(Map<String, dynamic> msg) {
    final js =
        'window.ktv && window.ktv.onMessage(${json.encode(json.encode(msg))});';
    controller.runJavaScript(js);
  }

  void _post(Map<String, dynamic> msg) {
    if (!_jsReady) {
      _queue.add(msg);
      return;
    }
    _send(msg);
  }

  /// Normalized 0..1 mouth-open value from TTS amplitude.
  @override
  void setLip(double value) => _post({'cmd': 'lipsync', 'value': value});

  @override
  void setSpeaking(bool on) => _post({'cmd': 'speaking', 'on': on});

  /// Play a named choreography: idle | dance | jump | swing | tilt | sleep.
  @override
  void playAction(String name) => _post({'cmd': 'action', 'name': name});

  void playMotion(String group) => _post({'cmd': 'motion', 'group': group});

  /// gaze x,y in -1..1
  void setGaze(double x, double y) => _post({'cmd': 'gaze', 'x': x, 'y': y});

  /// Map a mood token from the LLM reply to a gesture.
  @override
  void mood(String mood) {
    switch (mood) {
      case 'cheer':
        playAction('jump');
        break;
      case 'swing':
        playAction('dance');
        break;
      case 'tilt':
        playAction('tilt');
        break;
      case 'sleep':
        playAction('sleep');
        break;
      default:
        playAction('idle');
    }
  }
}
