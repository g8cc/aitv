import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/state/state_providers.dart';

class LogPage extends ConsumerWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B2430),
      appBar: AppBar(
        title: const Text('对话记录（仅文本，不含音频）'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder(
        future: ref.read(conversationLogProvider).recent(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(
                child: CircularProgressIndicator(color: Colors.white54));
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(
                child: Text('还没有记录', style: TextStyle(color: Colors.white54)));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final e = items[i];
              final ts = (e['ts'] as String? ?? '').replaceAll('T', ' ');
              return Card(
                color: Colors.white10,
                child: ListTile(
                  dense: true,
                  title: Text(
                      '[${e['mode']}] ${e['user'] ?? ''} → ${e['reply'] ?? ''}',
                      style:
                          const TextStyle(color: Colors.white, fontSize: 15)),
                  subtitle:
                      Text(ts, style: const TextStyle(color: Colors.white38)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
