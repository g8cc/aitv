import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/state/state_providers.dart';
import 'log_page.dart';
import 'mic_test_page.dart';

/// Numeric PIN pad used to gate all parent functions.
class PinGate extends ConsumerStatefulWidget {
  const PinGate({super.key});

  @override
  ConsumerState<PinGate> createState() => _PinGateState();
}

class _PinGateState extends ConsumerState<PinGate> {
  String _entry = '';
  String? _error;
  bool _verifying = false;

  Future<void> _press(String d) async {
    if (_verifying) return;
    setState(() {
      _error = null;
      if (_entry.length < 4) _entry += d;
    });
    if (_entry.length == 4) {
      final pin = _entry;
      _verifying = true;
      bool ok;
      try {
        ok = await ref.read(pinStoreProvider).verify(pin);
      } catch (e) {
        if (mounted) {
          setState(() {
            _verifying = false;
            _error = '验证暂时不可用，请稍后再试';
            _entry = '';
          });
        }
        return;
      }
      if (!mounted) return;
      _verifying = false;
      if (ok) {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ParentHome()));
        setState(() => _entry = '');
      } else {
        setState(() {
          _error = '密码不对，再试试';
          _entry = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B2430),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('家长验证',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(
                  4,
                  (i) => Padding(
                        padding: const EdgeInsets.all(6),
                        child: Container(
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _entry.length
                                ? Colors.amber
                                : Colors.white24,
                          ),
                        ),
                      )),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            const SizedBox(height: 8),
            _Pad(
                keys: [
                  for (final k in ['1', '2', '3', '4', '5', '6', '7', '8', '9'])
                    k,
                  'clear',
                  '0',
                  'back',
                ],
                onTap: (k) {
                  if (_verifying) return;
                  if (k == 'clear') {
                    setState(() => _entry = '');
                  } else if (k == 'back') {
                    setState(() => _entry = _entry.isNotEmpty
                        ? _entry.substring(0, _entry.length - 1)
                        : _entry);
                  } else {
                    _press(k);
                  }
                }),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回', style: TextStyle(color: Colors.white70)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pad extends StatelessWidget {
  final List<String> keys;
  final ValueChanged<String> onTap;
  const _Pad({required this.keys, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final k in keys)
          SizedBox(
            width: 72,
            height: 56,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white12,
                foregroundColor: Colors.white,
              ).copyWith(
                side: WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.focused)
                      ? const BorderSide(width: 3, color: Color(0xFF42A5F5))
                      : BorderSide.none,
                ),
              ),
              autofocus: k == '1',
              onPressed: () => onTap(k),
              child: Text(
                  k == 'clear'
                      ? 'C'
                      : k == 'back'
                          ? '⌫'
                          : k,
                  style: const TextStyle(fontSize: 22)),
            ),
          ),
      ],
    );
  }
}

/// Parent dashboard: settings + logs.
class ParentHome extends ConsumerWidget {
  const ParentHome({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.read(usageTrackerProvider);
    return Scaffold(
      backgroundColor: const Color(0xFF1B2430),
      appBar: AppBar(
        title: const Text('家长中心'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          ListTile(
            title: Text('今日已用 ${usage.usedSeconds ~/ 60} 分钟',
                style: const TextStyle(color: Colors.white)),
            subtitle: Text('上限 ${usage.limitMinutes} 分钟',
                style: const TextStyle(color: Colors.white54)),
          ),
          const SizedBox(height: 8),
          FilledButton(
            autofocus: true,
            onPressed: () async {
              final v = await showDialog<int>(
                context: context,
                builder: (_) => _LimitDialog(initial: usage.limitMinutes),
              );
              if (v != null) {
                usage.limitMinutes = v;
                if (usage.usedSeconds < v * 60) {
                  await ref.read(engineProvider).unlock();
                }
              }
            },
            child: const Text('调整每日时长上限 / 解除锁定'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.history),
            label: const Text('对话记录'),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const LogPage())),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.mic),
            label: const Text('麦克风自检 / 选择输入设备'),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const MicTestPage())),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.lock_reset),
            label: const Text('修改 PIN 码'),
            onPressed: () => showDialog(
                context: context, builder: (_) => const _SetPinDialog()),
          ),
        ],
      ),
    );
  }
}

class _LimitDialog extends StatefulWidget {
  final int initial;
  const _LimitDialog({required this.initial});

  @override
  State<_LimitDialog> createState() => _LimitDialogState();
}

class _LimitDialogState extends State<_LimitDialog> {
  late double _v;

  @override
  void initState() {
    super.initState();
    _v = widget.initial.clamp(5, 240).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('每日使用时长'),
      content: StatefulBuilder(
        builder: (_, setD) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${_v.round()} 分钟'),
            Slider(
              min: 5,
              max: 240,
              divisions: 47,
              value: _v,
              onChanged: (x) => setD(() => _v = x),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, _v.round()),
            child: const Text('确定')),
      ],
    );
  }
}

class _SetPinDialog extends ConsumerStatefulWidget {
  const _SetPinDialog();

  @override
  ConsumerState<_SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends ConsumerState<_SetPinDialog> {
  final _ctl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置新 PIN（4位数字）'),
      content: TextField(
        controller: _ctl,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        maxLength: 4,
        autofocus: true,
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () async {
            final v = _ctl.text;
            if (v.length == 4) {
              await ref.read(pinStoreProvider).setPin(v);
              if (context.mounted) Navigator.pop(context);
            }
          },
          child: const Text('保存'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }
}
