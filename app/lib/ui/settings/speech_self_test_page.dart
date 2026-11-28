import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../nativemedia/speaker_gate_bridge.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voiceprint_store.dart';
import '../../state/app_info.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// 语音功能的自测：把"采集 → 静默 → 打分 → 闸门"整条链路跑一遍，当场出结论。
///
/// 为什么要有这一页：这些问题（"要喊才行""谁都打断不了"）每次都要
/// 改代码 → 编译五分钟 → 装机 → 打电话 → 猜。一轮下来半小时，还常常猜错。
/// 这里的每一项都是直接调原生接口量出来的，不需要等模型、不需要真的打电话，
/// 也不需要外接电脑看 logcat。
///
/// 每一项都独立可跑：只想知道"麦克风是不是收得小"就点第一项，不用等全部。
class SpeechSelfTestPage extends ConsumerStatefulWidget {
  const SpeechSelfTestPage({super.key});

  @override
  ConsumerState<SpeechSelfTestPage> createState() => _SpeechSelfTestPageState();
}

/// 一项检查的结果。
///
/// [detail] 是要给人看的一句话；[raw] 是给复制用的原始值。
class _Result {
  const _Result(this.verdict, this.detail, {this.raw});

  final _Verdict verdict;
  final String detail;
  final String? raw;
}

enum _Verdict { pass, warn, fail, skipped }

class _SpeechSelfTestPageState extends ConsumerState<SpeechSelfTestPage> {
  final _channel = VoiceprintChannel();

  /// 每一项的结果，key 是 [checks] 里的 id。
  final _results = <String, _Result>{};
  String? _running;

  /// 采集探针的结果（三种音源各录 1.5 秒的峰值）。
  Map<String, double>? _sources;

  static const _checks = <({String id, String title, String hint})>[
    (
      id: 'sources',
      title: '各音源的采集电平',
      hint: '同一段时间分别用通话/识别/原始麦克风录 1.5 秒。差距大说明 AEC 在吃声音',
    ),
    (
      id: 'model',
      title: '声纹模型是否就绪',
      hint: '28MB 的 CAM++ 要加载几百毫秒到几秒；没就绪时所有判定都走原路径',
    ),
    (
      id: 'record',
      title: '录一段并算出声纹',
      hint: '3 秒录音 → 静默检测 → 嵌入向量。这一步不过，后面全是空谈',
    ),
    (
      id: 'match',
      title: '和自己已录入的模板比对',
      hint: '同一句话得到多少分。低于 accept 线说明阈值或音频有问题',
    ),
    (
      id: 'thresholds',
      title: '阈值一致性',
      hint: '设置算出来的 accept 和原生在用的是否一样。不一样说明配置没送到',
    ),
    (
      id: 'silence',
      title: '静默检测参数',
      hint: '这四项决定了「有没有人在说」；采得小的机器要调',
    ),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_run(['thresholds', 'silence']));
  }

  /// 跑指定的几项。全部跑就是传所有 id。
  Future<void> _run(List<String> ids) async {
    for (final id in ids) {
      if (!mounted) return;
      setState(() => _running = id);
      final r = await _one(id);
      if (!mounted) return;
      setState(() => _results[id] = r);
      // 每一项之间喘一下：录音、加载模型都不是瞬间的事，连着跑会互相抢资源。
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (mounted) setState(() => _running = null);
  }

  Future<_Result> _one(String id) async {
    try {
      return switch (id) {
        'sources' => await _probeSources(),
        'model' => await _probeModel(),
        'record' => await _probeRecord(),
        'match' => await _probeMatch(),
        'thresholds' => await _probeThresholds(),
        'silence' => await _probeSilence(),
        _ => const _Result(_Verdict.skipped, '未知项目'),
      };
    } on Object catch (e) {
      return _Result(_Verdict.fail, '出错了：$e');
    }
  }

  // ── 各项检查 ────────────────────────────────────────────────────────

  Future<_Result> _probeSources() async {
    final raw = await _channel.probeSources();
    if (raw.isEmpty) {
      return const _Result(_Verdict.fail, '拿不到任何音源，可能没有麦克风权限');
    }
    if (!mounted) return const _Result(_Verdict.skipped, '已离开');
    setState(() => _sources = raw);
    final vc = raw['VOICE_COMMUNICATION'];
    final mic = raw['MIC'];
    if (vc == null || vc <= -900) {
      return _Result(_Verdict.fail, '通话音源打不开（错误码 ${vc?.toInt()}）', raw: '$raw');
    }
    final text = StringBuffer('通话音源峰值 ${vc.toStringAsFixed(1)} dBFS');
    double? gap;
    if (mic != null && mic > -900) {
      gap = mic - vc;
      text.write('，原始麦克风 ${mic.toStringAsFixed(1)}（差 ${gap.toStringAsFixed(1)}dB）');
    }
    // 差距超过 20dB，说明 AEC/降噪在大量吃音量——这是"要喊才行"的根。
    final verdict = (gap != null && gap > 20) || vc < -45 ? _Verdict.warn : _Verdict.pass;
    return _Result(verdict, '$text', raw: '$raw');
  }

  Future<_Result> _probeModel() async {
    final ok = await _channel.available();
    final d = await _channel.describe();
    if (d == null) {
      return const _Result(_Verdict.fail, '原生没有响应，可能模型加载失败或被拦下');
    }
    final blocked = d['blocked'] == true;
    if (blocked) {
      return _Result(_Verdict.fail, '模型被原生拦下了（ONNX Runtime 不可用？）', raw: '$d');
    }
    if (!ok) {
      return _Result(_Verdict.warn, '模型还没就绪，等一下再试', raw: '$d');
    }
    return _Result(_Verdict.pass, '已就绪，模板 ${d['profiles']} 人', raw: '$d');
  }

  Future<_Result> _probeRecord() async {
    final ok = await _channel.startRecording();
    if (!ok) return const _Result(_Verdict.fail, '开不了录音（权限或设备被占）');
    await Future<void>.delayed(const Duration(milliseconds: 3000));
    final result = await _channel.stopRecording();
    if (result == null) {
      return const _Result(_Verdict.fail, '没录到东西');
    }
    var peak = 0.0;
    var sum = 0.0;
    for (final v in result.samples) {
      final a = v.abs();
      if (a > peak) peak = a;
      sum += v * v;
    }
    final peakDb = peak <= 0 ? -120.0 : 20 * math.log(peak) / math.ln10;
    final rmsDb = sum <= 0 ? -120.0 : 20 * math.log(math.sqrt(sum / result.samples.length)) / math.ln10;

    final vec = await _channel.embed(result.samples);
    if (vec == null || vec.isEmpty) {
      // 这一条最关键：说明静默检测把整段挡掉了，根本没算。
      return _Result(
        _Verdict.fail,
        '录音 ${(result.milliseconds / 1000).toStringAsFixed(1)} 秒，峰值 ${peakDb.toStringAsFixed(1)} dBFS，'
        '但算不出声纹——静默检测判定「没人在说」。把「收音大小」往下调',
        raw: 'peak=$peakDb rms=$rmsDb vec=null',
      );
    }
    _lastVector = vec;
    final verdict = peakDb < -45 ? _Verdict.warn : _Verdict.pass;
    return _Result(
      verdict,
      '${vec.length} 维向量已算出；峰值 ${peakDb.toStringAsFixed(1)}、RMS ${rmsDb.toStringAsFixed(1)} dBFS',
      raw: 'peak=$peakDb rms=$rmsDb dim=${vec.length}',
    );
  }

  Float32List? _lastVector;

  Future<_Result> _probeMatch() async {
    final profiles = await ref.read(voiceprintProfilesProvider.future);
    if (profiles.isEmpty) {
      return const _Result(_Verdict.skipped, '还没录入过声音');
    }
    final vec = _lastVector;
    if (vec == null) {
      return const _Result(_Verdict.skipped, '先跑「录一段并算出声纹」');
    }
    final closest = VoiceprintStore.closest(profiles, vec);
    final call = ref.read(callSettingsProvider);
    final accept = VoiceprintChannel.acceptFor(call.voiceprintLevel.wire, profiles.length) + call.voiceprintBias;
    final reject = accept - VoiceprintChannel.band;
    final score = closest.score;
    final kind = score >= accept ? 'YOU' : (score <= reject ? 'OTHER' : 'UNKNOWN');
    final margin = score - accept;
    return _Result(
      // 分差不足 0.05 就是"贴着线走"，同一句话换口气就会翻。
      margin >= 0.05 ? _Verdict.pass : (margin >= 0 ? _Verdict.warn : _Verdict.fail),
      '得分 ${score.toStringAsFixed(3)}，$kind（accept ${accept.toStringAsFixed(2)}，余量 ${margin.toStringAsFixed(3)}）',
      raw: 'score=$score accept=$accept reject=$reject kind=$kind',
    );
  }

  Future<_Result> _probeThresholds() async {
    final call = ref.read(callSettingsProvider);
    final profiles = await ref.read(voiceprintProfilesProvider.future);
    final dart = VoiceprintChannel.acceptFor(call.voiceprintLevel.wire, profiles.length) + call.voiceprintBias;
    final d = await _channel.describe();
    if (d == null) return const _Result(_Verdict.skipped, '读不到原生状态');
    final native = (d['accept'] as num?)?.toDouble();
    if (native == null) return _Result(_Verdict.warn, '原生没报 accept', raw: '$d');
    final same = (dart - native).abs() < 0.01;
    return _Result(
      same ? _Verdict.pass : _Verdict.fail,
      same
          ? '设置与原生一致（accept ${native.toStringAsFixed(3)}）'
          : '设置算出 ${dart.toStringAsFixed(3)}，原生在用 ${native.toStringAsFixed(3)}——配置没送到',
      raw: 'dart=$dart native=$native',
    );
  }

  Future<_Result> _probeSilence() async {
    final d = await _channel.describe();
    if (d == null) return const _Result(_Verdict.skipped, '读不到原生状态');
    final p = d['silencePercentile'];
    final x = d['silenceMultiple'];
    final f = d['silenceFloor'];
    final v = d['silenceVoicedFraction'];
    final floor = (f as num?)?.toDouble();
    // 旧版那个 3e-6 的教训：绝对下限一旦高于真实语音，整段都会被判静默。
    final risk = floor != null && floor > 1e-6;
    return _Result(
      risk ? _Verdict.warn : _Verdict.pass,
      'p=$p · x=$x · floor=$f · voiced=$v'
          '${risk ? '　⚠ 下限偏高，可能把整段判成静默' : ''}',
      raw: '$d',
    );
  }

  // ── 界面 ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = _results.length;
    final all = _checks.length;

    return AppPage.list(
      title: '语音自测',
      subtitle: const Text('不用打电话，当场把链路跑一遍'),
      actions: [
        TextButton(
          onPressed: _running != null ? null : () => _run(_checks.map((c) => c.id).toList()),
          child: Text(_running != null ? '跑着…' : '全部重跑'),
        ),
      ],
      children: [
        SettingsSection(
          title: '这一版',
          children: [
            SettingsTile(
              title: AppInfo.buildLabel,
              subtitle: '版本 ${AppInfo.displayVersion} · ${AppInfo.buildCommit.isEmpty ? '手工编译' : '提交 ${AppInfo.buildCommit}'}',
            ),
            SettingsTile(title: '进度', subtitle: '$done / $all 项跑过'),
          ],
        ),
        SettingsSection(
          title: '各项检查',
          children: [
            for (final c in _checks)
              SettingsTile(
                key: ValueKey('selftest-${c.id}'),
                title: c.title,
                subtitle: _results[c.id]?.detail ?? c.hint,
                danger: _results[c.id]?.verdict == _Verdict.fail,
                trailing: _running == c.id
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : switch (_results[c.id]?.verdict) {
                        _Verdict.pass => Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
                        _Verdict.warn => Icon(Icons.error_outline, size: 20, color: scheme.tertiary),
                        _Verdict.fail => Icon(Icons.cancel_outlined, size: 20, color: scheme.error),
                        _Verdict.skipped => Icon(Icons.remove_circle_outline, size: 20, color: scheme.outline),
                        null => Icon(Icons.play_circle_outline, size: 20, color: scheme.outline),
                      },
                onTap: _running != null ? null : () => _run([c.id]),
              ),
          ],
        ),
        if (_sources case final s?)
          SettingsSection(
            title: '音源对照（峰值 dBFS）',
            children: [
              for (final e in s.entries)
                SettingsTile(
                  title: e.key,
                  subtitle: e.value <= -900
                      ? '打不开（${e.value.toInt()}）'
                      : '${e.value.toStringAsFixed(1)} dBFS',
                ),
            ],
          ),
        SettingsSection(
          children: [
            SettingsTile(
              title: '复制报告',
              subtitle: '把这一页的结果贴出来',
              onTap: _copyAll,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _copyAll() async {
    final lines = <String>[
      'build: ${AppInfo.buildLabel}',
      'version: ${AppInfo.displayVersion}',
      for (final c in _checks)
        '${c.id}: ${_results[c.id]?.verdict.name ?? "未跑"} — ${_results[c.id]?.detail ?? ""}'
            '${_results[c.id]?.raw == null ? "" : "  [${_results[c.id]!.raw}]"}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
    }
  }
}
