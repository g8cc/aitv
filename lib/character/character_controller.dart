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
  bool _failed = false;
  final _queue = <Map<String, dynamic>>[];
  Map<String, dynamic>? _pendingLip;
  Timer? _lipTimer;

  CharacterController() : controller = WebViewController() {
    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel('KtvBridge', onMessageReceived: _onBridge);
    unawaited(controller
        .loadFlutterAsset('assets/live2d/viewer.html')
        .catchError((Object error) {
      _failed = true;
      _queue.clear();
      if (!_ready.isCompleted) _ready.completeError(error);
    }));
  }

  @override
  Future<void> get ready => _ready.future;

  void _onBridge(JavaScriptMessage msg) {
    try {
      final j = json.decode(msg.message) as Map<String, dynamic>;
      if (j['event'] == 'ready') {
        if (_failed) return;
        _jsReady = true;
        for (final m in _queue) {
          _send(m);
        }
        _queue.clear();
        if (!_ready.isCompleted) _ready.complete();
      } else if (j['event'] == 'error') {
        _failed = true;
        _queue.clear();
        if (!_ready.isCompleted) {
          _ready.completeError(StateError(
              j['message']?.toString() ?? 'Live2D WebView failed to load'));
        }
      }
    } catch (_) {}
  }

  void _send(Map<String, dynamic> msg) {
    final js =
        'window.ktv && window.ktv.onMessage(${json.encode(json.encode(msg))});';
    unawaited(controller.runJavaScript(js).catchError((_) {}));
  }

  void _post(Map<String, dynamic> msg) {
    if (_failed) return;
    if (!_jsReady) {
      if (msg['cmd'] == 'lipsync') {
        final index = _queue.lastIndexWhere((m) => m['cmd'] == 'lipsync');
        if (index >= 0) {
          _queue[index] = msg;
          return;
        }
      }
      if (_queue.length >= 64) _queue.removeAt(0);
      _queue.add(msg);
      return;
    }
    _send(msg);
  }

  /// Normalized 0..1 mouth-open value from TTS amplitude.
  @override
  void setLip(double value) {
    if (!_jsReady) {
      _post({'cmd': 'lipsync', 'value': value});
      return;
    }
    _pendingLip = {'cmd': 'lipsync', 'value': value};
    _lipTimer ??= Timer(const Duration(milliseconds: 50), () {
      _lipTimer = null;
      final msg = _pendingLip;
      _pendingLip = null;
      if (msg != null && !_failed) _send(msg);
    });
  }

  @override
  void setSpeaking(bool on) {
    if (!on) {
      _lipTimer?.cancel();
      _lipTimer = null;
      _pendingLip = null;
    }
    _post({'cmd': 'speaking', 'on': on});
  }

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
