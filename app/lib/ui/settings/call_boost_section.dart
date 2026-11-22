import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../nativemedia/speaker_gate_bridge.dart' show GainMeasurement, VoiceprintChannel;
import '../../speech/speech_audio.dart';
import '../../speech/speech_settings.dart';
import 'choice_list_page.dart';
import 'graded_slider_tile.dart';
import 'settings_widgets.dart';

/// 通话增强：通道、增益、插话灵敏度。
///
/// 和声纹那张卡是**两条独立的链**：
/// - 这里决定「声音怎么进来、多容易被打断」
/// - 声纹卡决定「是不是你」
///
/// 所以本卡**不受声纹总闸影响**，恒可用——声纹关掉之后，打断、唤醒、
/// 断句仍要走这条采集流。
class CallBoostSection extends ConsumerStatefulWidget {
  const CallBoostSection({super.key});

  @override
  ConsumerState<CallBoostSection> createState() => _CallBoostSectionState();
}

class _CallBoostSectionState extends ConsumerState<CallBoostSection> {
  bool _measuring = false;
  GainMeasurement? _result;
  String? _note;

  /// 增益换算成分贝，给副标题用。
  String _gainText(double gain) =>
      gain <= 1.001 ? '不放大' : '+${(20 * (math.log(gain) / math.ln10)).toStringAsFixed(1)} dB';

  Future<void> _measure() async {
    setState(() {
      _measuring = true;
      _note = null;
      _result = null;
    });
    try {
      final m = await VoiceprintChannel().measureGain(ms: 3000);
      if (!mounted) return;
      if (m == null) {
        setState(() {
          _measuring = false;
          _note = '这一段几乎没听到声音，没法算。检查麦克风权限，再正常音量说一句';
        });
        return;
      }
      await VoiceprintChannel().setGain(m.gain);
      await ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(micGain: m.gain));
      if (!mounted) return;
      setState(() {
        _measuring = false;
        _result = m;
        _note = m.gain <= 1.001 ? '已经够响，保持不放大' : '已设成 ${m.gain.toStringAsFixed(2)}×';
      });
    } finally {
      if (mounted && _measuring) setState(() => _measuring = false);
    }
  }

  Future<void> _pickSource(CallSettings call) async {
    final picked = await showChoicePage<CallMicSource>(
      context,
      title: '麦克风音源',
      selected: call.callMicSource,
      footer: '改完下一次通话生效。若打断总是不灵，先在这里换一路试试——'
          '有的机器会把通话音源的人声压掉，换识别那一路反而更清楚。',
      options: const [
        ChoiceOption(
          CallMicSource.communication,
          '通话（推荐）',
          subtitle: '带回声消除和降噪，自己播的声音不会漏回来。缺点是有的机器会把人声也压小',
        ),
        ChoiceOption(
          CallMicSource.recognition,
          '语音识别',
          subtitle: '不降噪，电平通常更高。缺点是自己播的声音会漏回麦克风，可能自己打断自己',
        ),
        ChoiceOption(
          CallMicSource.auto,
          '自动检测',
          subtitle: '接通时分别量三种音源各 1.5 秒再挑，要让用户多等约 4.5 秒',
        ),
      ],
    );
    if (picked == null || !mounted) return;
    await ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(callMicSource: picked));
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callSettingsProvider);
    return SettingsSection(
      title: '通话增强',
      footer: const Text('这一组决定声音怎么进来、多容易被打断，和声纹是两条独立的链，声纹关掉也照常生效'),
      children: [
        SettingsTile(
          key: const ValueKey('call-mic-source'),
          title: '麦克风音源',
          subtitle: _sourceHint(call.callMicSource),
          value: Text(call.callMicSource.label),
          onTap: () => unawaited(_pickSource(call)),
        ),
        GradedSliderTile(
          key: const ValueKey('call-mic-gain'),
          title: '麦克风增益',
          subtitle: _note ?? '采集后放大 ${call.micGain.toStringAsFixed(2)}×（${_gainText(call.micGain)}）。'
              '有的机器给人声的增益很低，放大后才够判',
          value: call.micGain,
          min: 1.0,
          max: 8.0,
          grades: const [
            (1.0, '1×'),
            (2.0, '2×'),
            (4.0, '4×'),
            (8.0, '8×'),
          ],
          format: (v) => '${v.toStringAsFixed(2)}×',
          onCommit: (v) => unawaited(
            ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(micGain: v)),
          ),
        ),
        SettingsTile(
          key: const ValueKey('call-mic-gain-measure'),
          title: _measuring ? '正在录 3 秒……' : '量一下',
          subtitle: _measuring
              ? '现在用正常音量说一句话'
              : '不知道设多少就点这里：录 3 秒，我按正常说话的响度反推一个倍数',
          trailing: _measuring
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : null,
          onTap: _measuring ? null : () => unawaited(_measure()),
        ),
        if (_result case final m?)
          SettingsTile(
            key: const ValueKey('call-mic-gain-result'),
            title: '这次量到 ${m.peakDb.toStringAsFixed(1)} dBFS',
            subtitle: '建议 ${m.gain.toStringAsFixed(2)}×'
                '${m.windows < 100 ? '（录音太短，结果可能不准）' : ''}',
          ),
      ],
    );
  }

  String _sourceHint(CallMicSource s) => switch (s) {
    CallMicSource.communication => '带回声消除，自己播的声音不漏回来',
    CallMicSource.recognition => '电平通常更高，但回声会漏回来',
    CallMicSource.auto => '接通时量三种音源再挑，要多等约 4.5 秒',
  };
}
