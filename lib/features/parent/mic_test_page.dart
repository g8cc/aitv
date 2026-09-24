import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/audio/audio_input.dart';
import '../../core/audio/pcm_util.dart';
import '../../core/audio/wav_util.dart';
import '../../core/state/state_providers.dart';

/// Lets a parent find out, on the actual TV, which recording input (if any)
/// carries sound: list devices, record a few seconds with a live level meter,
/// play it back, and keep the one that worked.
class MicTestPage extends ConsumerStatefulWidget {
  const MicTestPage({super.key});

  @override
  ConsumerState<MicTestPage> createState() => _MicTestPageState();
}

class _MicTestPageState extends ConsumerState<MicTestPage> {
  static const testSeconds = 3;
  static const sampleRate = 16000;

  /// Android's AudioDeviceInfo.TYPE_BUILTIN_MIC.
  static const _typeBuiltinMic = 15;

  final AudioInput _input = MethodChannelAudioInput();
  final AudioPlayer _player = AudioPlayer();

  List<AudioInputDevice> _devices = const [];
  String? _loadError;
  int _selected = -1;
  String? _selectedName;

  bool _testing = false;
  double _level = 0;
  double _peak = 0;
  String? _verdict;
  String? _detail;
  Uint8List? _recorded;
  String? _playbackPath;

  @override
  void initState() {
    super.initState();
    final mic = ref.read(micSettingsProvider);
    _selected = mic.inputIndex;
    _selectedName = mic.inputName;
    unawaited(_loadDevices());
  }

  @override
  void dispose() {
    unawaited(_player.dispose());
    super.dispose();
  }

  Future<void> _loadDevices() async {
    try {
      final list = await _input.listDevices();
      if (!mounted) return;
      setState(() {
        _devices = list;
        _loadError = list.isEmpty
            ? '系统没有报告任何录音输入设备。这台电视大概率不能自行拾音，'
                '需要外接 USB 麦克风，或用手机当麦克风。'
            : null;
      });
    } on PlatformException catch (e) {
      _fail('读取输入设备失败：${e.message ?? e.code}');
    } catch (e) {
      _fail('这个平台没有原生音频输入通道（只能在安卓电视/盒子上自检）：$e');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _loadError = message;
      _devices = const [];
    });
  }

  Future<bool> _ensurePermission() async {
    final status = await Permission.microphone.request();
    if (status.isGranted) return true;
    if (mounted) {
      setState(() => _verdict = '没有拿到录音权限，请在系统设置里允许本应用录音。');
    }
    return false;
  }

  Future<void> _runTest() async {
    if (_testing) return;
    if (!await _ensurePermission()) return;
    setState(() {
      _testing = true;
      _level = 0;
      _peak = 0;
      _verdict = null;
      _detail = null;
      _recorded = null;
    });

    final engine = ref.read(engineProvider);
    await engine.pauseMic();
    final collected = BytesBuilder(copy: true);
    final mic = NativeMic(
        input: _input,
        inputIndex: _selected,
        inputName: _selectedName,
        sampleRate: sampleRate);
    final sub = mic.frames.listen((frame) {
      collected.add(frame);
      final rms = PcmUtil.rms(frame);
      if (!mounted) return;
      setState(() {
        _level = rms;
        if (rms > _peak) _peak = rms;
      });
    });

    try {
      await mic.start();
      final info = mic.startInfo;
      _detail = info == null
          ? null
          : '音频源：${info.audioSource}，设备：${info.productName}';
      await Future<void>.delayed(const Duration(seconds: testSeconds));
      if (_peak > 0.004) {
        _recorded = Uint8List.fromList(collected.takeBytes());
        _verdict = '能收到声音（峰值 ${(_peak * 100).toStringAsFixed(1)}%），'
            '回放确认是你的声音后点「用这个设备」。';
      } else {
        _verdict = '这 $testSeconds 秒全程静音，换一个输入设备再试。';
      }
    } on PlatformException catch (e) {
      _verdict = '无法从这个设备采集：${e.message ?? e.code}';
    } catch (e) {
      _verdict = '无法从这个设备采集：$e';
    } finally {
      await sub.cancel();
      await mic.dispose();
      await engine.restartMic();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _playBack() async {
    final pcm = _recorded;
    if (pcm == null) return;
    try {
      var path = _playbackPath;
      if (path == null) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/mic_test.wav');
        await file.writeAsBytes(WavUtil.wrapPcm16(pcm, sampleRate));
        path = _playbackPath = file.path;
      }
      await _player.setAudioSource(AudioSource.file(path));
      await _player.seek(Duration.zero);
      await _player.play();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('回放失败：$e')));
      }
    }
  }

  Future<void> _applyDevice() async {
    final mic = ref.read(micSettingsProvider);
    if (_selected < 0) {
      await mic.useSystemDefault();
    } else {
      await mic.setDevice(index: _selected, name: _selectedName);
    }
    await ref.read(engineProvider).restartMic();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('已保存，语音对话改用这个麦克风。')));
  }

  String? _ratesLabel(AudioInputDevice d) {
    if (d.sampleRates.isEmpty) return null;
    final ok = d.supportsRate(sampleRate);
    return '${ok ? '' : '不支持 $sampleRate Hz，可能录不到音 · '}'
        '采样率 ${d.sampleRates.join(' ')}';
  }

  String _label(AudioInputDevice d) =>
      '${d.index == _selected ? '● ' : '　'}#${d.index} ${d.productName}'
      '${d.type == _typeBuiltinMic ? '（内置）' : ''}';

  @override
  Widget build(BuildContext context) {
    final error = _loadError;
    return Scaffold(
      backgroundColor: const Color(0xFF1B2430),
      appBar: AppBar(
        title: const Text('麦克风自检'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            '遥控器上的语音键是给系统语音助手用的，第三方应用拿不到，'
            '所以拾音要靠本应用自己的麦克风。\n'
            '电视上说话没反应，通常是默认输入设备是空的：插一个 USB '
            '麦克风（或带麦的耳机），在下面逐个设备录 '
            '$testSeconds 秒，音量条动了的那个就能用。',
            style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
          ),
          const SizedBox(height: 16),
          if (error != null)
            Card(
              color: Colors.red.shade900.withValues(alpha: 0.4),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(error,
                    style: const TextStyle(color: Colors.white, fontSize: 16)),
              ),
            )
          else ...[
            Text('输入设备（${_devices.length} 个）',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _deviceRow(-1, '系统默认（record 插件）', null),
                for (final d in _devices)
                  _deviceRow(d.index, _label(d), _ratesLabel(d)),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Row(
            children: [
              FilledButton.icon(
                autofocus: true,
                onPressed: _testing || error != null ? null : _runTest,
                icon: const Icon(Icons.mic),
                label: Text(_testing ? '正在录 $testSeconds 秒…' : '开始测试'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _recorded == null ? null : _playBack,
                icon: const Icon(Icons.play_arrow),
                label: const Text('回放刚才的录音'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _LevelBar(level: _level, peak: _peak),
          const SizedBox(height: 8),
          if (_detail != null)
            Text(_detail!, style: const TextStyle(color: Colors.white54)),
          if (_verdict != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_verdict!,
                  style: TextStyle(
                      color: _recorded == null
                          ? Colors.orangeAccent
                          : Colors.lightGreenAccent,
                      fontSize: 17)),
            ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _testing ? null : _applyDevice,
            icon: const Icon(Icons.check),
            label: Text(_selected < 0 ? '保持系统默认' : '用这个设备'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _deviceRow(int index, String label, String? extra) {
    final selected = index == _selected;
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: Colors.white12,
      leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? Colors.amber : Colors.white38),
      title: Text(label, style: const TextStyle(color: Colors.white)),
      subtitle: extra == null
          ? null
          : Text(extra, style: const TextStyle(color: Colors.white38, fontSize: 12)),
      onTap: () => setState(() {
        _selected = index;
        _selectedName = index < 0
            ? null
            : _devices.firstWhere((d) => d.index == index).productName;
        _verdict = null;
        _level = 0;
        _peak = 0;
        _recorded = null;
        _playbackPath = null;
      }),
    );
  }
}

/// Live RMS meter with a peak-hold marker; speech sits well below full scale,
/// so the bar is amplified to make small levels visible from across the room.
class _LevelBar extends StatelessWidget {
  final double level;
  final double peak;
  const _LevelBar({required this.level, required this.peak});

  static const _gain = 6.0;

  @override
  Widget build(BuildContext context) {
    final width = math.min(1.0, level * _gain);
    final peakPos = math.min(1.0, peak * _gain);
    return LayoutBuilder(builder: (_, box) {
      return SizedBox(
        height: 28,
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
            ),
            Positioned(
              left: 0,
              top: 4,
              bottom: 4,
              width: box.maxWidth * width,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                      colors: [Color(0xFF42A5F5), Color(0xFF66BB6A)]),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            if (peak > 0)
              Positioned(
                left: box.maxWidth * peakPos - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: Colors.amber),
              ),
          ],
        ),
      );
    });
  }
}
