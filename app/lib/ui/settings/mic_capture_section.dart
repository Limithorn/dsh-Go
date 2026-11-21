import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../nativemedia/speaker_gate_bridge.dart' show GainMeasurement, VoiceprintChannel;
import '../../speech/speech_audio.dart';
import 'settings_widgets.dart';
import 'voice_level_meter.dart';

/// 「怎么收声」这一整块：音源、增益、实时电平，放在一起。
///
/// 为什么合成一块而不是分散在三页：这三件其实是同一个问题的三个参数——
/// 麦克风给什么（音源）、放大多少（增益）、结果够不够（电平）。分开摆的
/// 时候，调增益要翻页、看电平又要翻回去，改一次要跳三趟。
///
/// 合并前这些散在：实景测试页（音源 + 增益）、AEC 诊断页（音源）、
/// 语音链路诊断页（电平）三处，同一个设置改了不知道有没有生效。
class MicCaptureSection extends StatefulWidget {
  const MicCaptureSection({
    super.key,
    required this.source,
    required this.gain,
    required this.onSource,
    required this.onGain,
    this.busy = false,
    this.liveDb,
  });

  final CallMicSource source;
  final double gain;
  final ValueChanged<CallMicSource>? onSource;
  final ValueChanged<double>? onGain;

  /// 通话或测试正在跑：这时不量增益（会抢麦克风）。
  final bool busy;

  /// 实时电平（dBFS）。null 表示现在没在采。
  final double? liveDb;

  @override
  State<MicCaptureSection> createState() => _MicCaptureSectionState();
}

class _MicCaptureSectionState extends State<MicCaptureSection> {
  bool _measuring = false;
  GainMeasurement? _result;
  String? _note;

  /// 增益换算成分贝，给副标题用。
  String get _gainDb {
    if (widget.gain <= 1.001) return '不放大';
    return '+${(20 * (math.log(widget.gain) / math.ln10)).toStringAsFixed(1)} dB';
  }

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
      widget.onGain?.call(m.gain);
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = widget.liveDb;
    return SettingsSection(
      title: '怎么收声',
      children: [
        // 实时电平。放在最上面：调下面两个之前，先看清楚现在是什么状况。
        SettingsTile(
          key: const ValueKey('mic-live-level'),
          title: live == null ? '电平：没在采' : '电平 ${live.toStringAsFixed(0)} dBFS',
          subtitle: live == null
              ? '下面改了之后，进「实景测试」或打一通电话就能看到实时电平'
              : _levelAdvice(live),
          trailing: live == null
              ? null
              : SizedBox(
                  width: 140,
                  child: VoiceLevelMeter(
                    db: live,
                    floor: -68,
                    // 说话要比底噪高出 12dB 才算清楚；增益调对了这一条能一直过线。
                    needed: 12,
                    span: 36,
                  ),
                ),
        ),
        SettingsSegmentTile<CallMicSource>(
          key: const ValueKey('mic-source'),
          title: '音源',
          subtitle: switch (widget.source) {
            CallMicSource.auto =>
              '启动时量两路电平，通话那一路低 20dB 以上就换识别——和通话用的是同一次判断',
            CallMicSource.communication =>
              '带 AEC，自己播的声音不会漏回来；但有的机器会把人声也压掉',
            CallMicSource.recognition =>
              '不降噪、电平通常更高，但自己播的声音会漏回来',
          },
          segments: const [
            PillSegment(CallMicSource.auto, '自动'),
            PillSegment(CallMicSource.communication, '通话'),
            PillSegment(CallMicSource.recognition, '识别'),
          ],
          selected: widget.source,
          onChanged: widget.onSource,
        ),
        SettingsTile(
          key: const ValueKey('mic-gain'),
          title: '增益 ${widget.gain.toStringAsFixed(2)}×（$_gainDb）',
          subtitle: _note ??
              '有的机器给第三方 App 的录音增益很低，人声太小、打断不了。'
                  '点一下说 3 秒正常音量的话，我按 -30dBFS 反推一个固定倍数。'
                  '用固定倍数而不是每段归一化：归一化会把 AI 的回声和底噪一起抬满',
          onTap: (_measuring || widget.busy)
              ? null
              : () => unawaited(_measure()),
        ),
        if (_measuring)
          SettingsTile(
            key: const ValueKey('mic-gain-recording'),
            title: '正在录 3 秒……现在正常音量说一句话',
            trailing: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
            ),
          ),
        if (_result != null)
          Builder(
            builder: (context) {
              final m = _result!;
              return SettingsTile(
                key: const ValueKey('mic-gain-result'),
                title: '这次量到 ${m.peakDb.toStringAsFixed(1)} dBFS'
                    '${m.windows < 100 ? '（录音太短，结果可能不准）' : ''}',
                subtitle: m.gain <= 1.001
                    ? '已经够响，不用放大'
                    : '建议 ${m.gain.toStringAsFixed(2)}×'
                        '，即抬高约 ${(20 * (math.log(m.gain) / math.ln10)).toStringAsFixed(1)} dB'
                        '${m.currentGain > 1.001 ? '\n这次是在已放大 ${m.currentGain.toStringAsFixed(2)}× 的基础上量的，新值已折算' : ''}',
              );
            },
          ),
      ],
    );
  }

  /// 把电平翻译成一句人话。
  ///
  /// 光给数字没用——-40 是好是坏取决于底噪。所以对照的是「比正常录音
  /// 该有的 -18dBFS 差多少」，直接说要怎么办。
  String _levelAdvice(double db) {
    if (db > -12) return '偏大，可能会削顶。增益调小一些';
    if (db > -24) return '正常说话的响度';
    if (db > -36) return '偏小。点下面的「增益」量一下，或者靠近麦克风';
    return '很小。多半是音源或增益不对，也可能麦克风被占用';
  }
}
