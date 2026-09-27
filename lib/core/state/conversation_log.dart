import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Text-only conversation log (never raw audio). Viewable from the parent
/// panel. Stored as JSON lines.
class ConversationLog {
  static const _fileName = 'conversation_log.jsonl';
  static const _maxBytes = 512 * 1024;
  static const _maxRetainedLines = 200;
  File? _file;
  Future<void> _writeQueue = Future<void>.value();

  Future<File> _open() async {
    if (_file != null) return _file!;
    final dir = await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/$_fileName');
    return _file!;
  }

  Future<void> append({
    required String mode,
    String? user,
    String? reply,
  }) {
    final operation = _writeQueue.then((_) async {
      await _append(
        mode: mode,
        user: user,
        reply: reply,
      );
    });
    _writeQueue = operation.catchError((_) {});
    return operation;
  }

  Future<void> _append({
    required String mode,
    String? user,
    String? reply,
  }) async {
    final f = await _open();
    final line = json.encode({
      'ts': DateTime.now().toIso8601String(),
      'mode': mode,
      if (user != null) 'user': user,
      if (reply != null) 'reply': reply,
    });
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
    if (await f.length() <= _maxBytes) return;

    final lines = await f.readAsLines();
    final start =
        lines.length > _maxRetainedLines ? lines.length - _maxRetainedLines : 0;
    await f.writeAsString('${lines.sublist(start).join('\n')}\n', flush: true);
  }

  /// Newest first, capped.
  Future<List<Map<String, dynamic>>> recent({int limit = 200}) async {
    await _writeQueue;
    final f = await _open();
    if (!await f.exists()) return [];
    final lines = await f.readAsLines();
    final out = <Map<String, dynamic>>[];
    for (var i = lines.length - 1; i >= 0 && out.length < limit; i--) {
      try {
        out.add(json.decode(lines[i]) as Map<String, dynamic>);
      } catch (_) {}
    }
    return out;
  }

  Future<void> clear() async {
    final operation = _writeQueue.then((_) async {
      final f = await _open();
      if (await f.exists()) await f.delete();
    });
    _writeQueue = operation.catchError((_) {});
    await operation;
  }
}
