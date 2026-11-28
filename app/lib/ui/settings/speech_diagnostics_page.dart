import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../nativemedia/speaker_gate_bridge.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voiceprint_store.dart';
import '../../state/app_info.dart';
import '../../state/voice_call_host.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// 语音链路诊断：把"从麦克风到一句回复"这条路上每一道闸的当前值都摆出来。
///
/// 为什么单开一页：这些数分散在 Dart 设置、原生 Thresholds、KaldiFbank 三处，
/// 出问题时（"谁都打断不了""要喊才行"）光看设置页的滑块根本判断不了是哪个
/// 环节卡住——实测就踩过：设置页显示"声纹已开、阈值 0.50"，而原生侧因为
/// 静默检测把每一帧都判成静默，`embed` 返回 null，压根没走到打分那一步。
///
/// 所以这里并排放两组东西：
/// - **设置里写了什么**（Dart 侧，用户能改的）
/// - **原生真正在用什么**（`voiceprintDescribe` 读回来的）
///
/// 两者对不上 = 配置没送到；都对得上但还是不工作 = 算法本身的问题。
class SpeechDiagnosticsPage extends ConsumerStatefulWidget {
  const SpeechDiagnosticsPage({super.key, this.embedded = false});

  /// 装进 Tab 里：不画大标题，只留列表体。
  final bool embedded;

  @override
  ConsumerState<SpeechDiagnosticsPage> createState() => _SpeechDiagnosticsPageState();
}

class _SpeechDiagnosticsPageState extends ConsumerState<SpeechDiagnosticsPage> {
  Map<String, Object?>? _native;
  bool _loading = true;

  /// 现场录一段看电平——这一页最有用的东西。
  ///
  /// "是不是我机器收得小"这种问题，靠猜永远猜不对：实测那台要喊才有反应的
  /// 机器，说话整段 RMS 只有 −60dBFS。录三秒，把峰值/RMS/每个静默参数都算
  /// 出来，一眼就知道该把「收音大小」调到哪一档。
  bool _recording = false;
  ({double peak, double rms, int ms})? _probe;

  final _channel = VoiceprintChannel();

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final n = await _channel.describe();
    if (!mounted) return;
    setState(() {
      _native = n;
      _loading = false;
    });
  }

  Future<void> _probeOnce() async {
    setState(() {
      _recording = true;
      _probe = null;
    });
    final ok = await _channel.startRecording();
    if (!ok) {
      if (mounted) setState(() => _recording = false);
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 3000));
    final result = await _channel.stopRecording();
    if (!mounted) return;
    setState(() {
      _recording = false;
      if (result == null || result.samples.isEmpty) return;
      var peak = 0.0;
      var sum = 0.0;
      for (final v in result.samples) {
        final a = v.abs();
        if (a > peak) peak = a;
        sum += v * v;
      }
      final rms = (sum / result.samples.length);
      _probe = (
        // ±1.0 满刻度 → dBFS。0 直接给 −120，别出 -inf。
        peak: peak <= 0 ? -120.0 : 20 * math.log(peak) / math.ln10,
        rms: rms <= 0 ? -120.0 : 20 * math.log(math.sqrt(rms)) / math.ln10,
        ms: result.milliseconds,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callSettingsProvider);
    final profiles = ref.watch(voiceprintProfilesProvider).value ?? const <VoiceProfile>[];
    final native = _native;
    final acceptDart = VoiceprintChannel.acceptFor(call.voiceprintLevel.wire, profiles.length) + call.voiceprintBias;

    String n(String key, [String fallback = '—']) {
      final v = native?[key];
      if (v == null) return fallback;
      if (v is double) return v.toStringAsFixed(3);
      return '$v';
    }

    return AppPage.list(
      showLargeTitle: !widget.embedded,
      title: '语音链路诊断',
      subtitle: const Text('这几项各自管什么、现在是什么值'),
      actions: [
        IconButton(
          onPressed: _loading ? null : _refresh,
          icon: _loading
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
          tooltip: '重新读取',
        ),
      ],
      children: [
        // ── 这一版是哪一版 ────────────────────────────────────────────
        SettingsSection(
          title: '这一版',
          children: [
            SettingsTile(
              title: AppInfo.buildLabel,
              subtitle: '版本 ${AppInfo.displayVersion} · 提交 ${AppInfo.buildCommit.isEmpty ? '—' : AppInfo.buildCommit}'
                  '${AppInfo.buildTime.isEmpty ? '' : ' · 打包于 ${AppInfo.buildTime}'}',
            ),
          ],
        ),

        // ── 采集链路 ──────────────────────────────────────────────────
        SettingsSection(
          title: '采集链路',
          children: [
            const _Explain(
              title: '麦克风 → AEC → 16k 单声道',
              subtitle: '通话和声纹录入都走这一条，分布一致，分数才对得上',
            ),
            SettingsTile(
              key: const ValueKey('diag-probe'),
              title: _recording ? '正在录…' : '测一下收音（3 秒）',
              subtitle: _probe == null
                  ? '对着手机正常说一句话，看进到麦克风里有多大'
                  : '峰值 ${_probe!.peak.toStringAsFixed(1)} dBFS · '
                        'RMS ${_probe!.rms.toStringAsFixed(1)} dBFS · '
                        '${(_probe!.ms / 1000).toStringAsFixed(1)} 秒',
              onTap: _recording ? null : _probeOnce,
            ),
            if (_probe case final p?)
              _Explain(
                title: _verdictFor(p.rms),
                subtitle: '正常手机说话 RMS 约 −25 到 −18 dBFS；低于 −45 就该把「这台机器收音大小」往下调',
                danger: p.rms < -45,
              ),
          ],
        ),

        // ── 静默检测 ──────────────────────────────────────────────────
        SettingsSection(
          title: '静默检测（第一道门）',
          children: [
            const _Explain(
              title: '先判断「这段里到底有没有人说话」',
              subtitle: '没过这一关，后面打分、比对全部不执行——表现是「加了设置也没反应」',
            ),
            SettingsTile(
              title: '取第几分位当底',
              subtitle: 'percentile = ${n('silencePercentile')}　'
                  '越小越贴近数字静默，越大越容易吃到人声',
              trailing: _Same(dart: call.voiceprintMic.percentile, native: native?['silencePercentile']),
            ),
            SettingsTile(
              title: '比底高多少倍算有人声',
              subtitle: 'multiple = ${n('silenceMultiple')}　'
                  '4.0 约合 +6dB；采集越小，这值该越小',
              trailing: _Same(dart: call.voiceprintMic.multiple, native: native?['silenceMultiple']),
            ),
            SettingsTile(
              title: '绝对下限',
              subtitle: 'floor = ${n('silenceFloor')}　'
                  '只在底趋近 0 时兜底，高于真实语音就会把整段判成静默',
              trailing: _Same(dart: call.voiceprintMic.absoluteFloor, native: native?['silenceFloor']),
            ),
            SettingsTile(
              title: '多少比例的帧有声才算在说',
              subtitle: 'voicedFraction = ${n('silenceVoicedFraction')}　'
                  '实测本人说话时约 68% 的帧有声',
              trailing: _Same(dart: call.voiceprintMic.voicedFraction, native: native?['silenceVoicedFraction']),
            ),
          ],
        ),

        // ── 声纹打分 ──────────────────────────────────────────────────
        SettingsSection(
          title: '声纹打分（第二道门）',
          children: [
            _Explain(
              title: '拿这段跟已录入的声音比余弦',
              subtitle: '已录入 ${profiles.length} 人 · 模型${n('ready') == 'true' ? '已就绪' : '未就绪'}'
                  '${n('blocked') == 'true' ? ' · 已被拦下' : ''}',
            ),
            SettingsTile(
              title: '接受线（本人）',
              subtitle: 'accept = ${n('accept')}　高于它才认成自己人'
                  '${(acceptDart - double.tryParse(n('accept'))!).abs() > 0.01 ? '　⚠ 设置算出 $acceptDart' : ''}',
              trailing: _Same(dart: acceptDart, native: native?['accept']),
            ),
            SettingsTile(
              title: '拒绝线（旁人）',
              subtitle: 'reject = ${n('reject')}　低于它直接当旁人，中间是「不确定」不打断',
            ),
            SettingsTile(
              title: '不确定带宽',
              subtitle: 'band = ${n('band')}　accept 与 reject 之间留的缓冲，防抖',
            ),
            SettingsTile(
              title: '识别灵敏度',
              subtitle: 'level = ${n('level')}　loose 0.40 / normal 0.50 / strict 0.60 起算',
            ),
            SettingsTile(
              title: '这台机器微调',
              subtitle: 'bias = ${n('bias')}　手动挪 accept 线，−0.20 ~ +0.20',
            ),
          ],
        ),

        // ── 三道闸 ────────────────────────────────────────────────────
        SettingsSection(
          title: '三道闸各自的线',
          children: [
            const _Explain(
              title: '同一个人的声音，在不同场景下分数不一样',
              subtitle: '通话有 AEC 削分、唤醒没有，所以三条线分开定，不能共用',
            ),
            SettingsTile(title: '打断（有播放、有 AEC）', subtitle: 'accept = ${n('acceptBarge')}　最宽松，因为 AEC 削掉的分数补不回来'),
            SettingsTile(title: '唤醒（无播放、无 AEC）', subtitle: 'accept = ${n('acceptWake')}　最严格，音频和录入时接近'),
            SettingsTile(title: '轮次（判断说完了没）', subtitle: 'accept = ${n('acceptTurn')}　居中'),
          ],
        ),

        // ── 开关状态 ──────────────────────────────────────────────────
        SettingsSection(
          title: '开关',
          children: [
            SettingsTile(
              title: '声纹总开关',
              subtitle: 'enabled = ${n('enabled')}　${call.voiceprint ? '设置里开着' : '设置里关着'}',
              trailing: _Same(dart: call.voiceprint, native: native?['enabled']),
            ),
            SettingsTile(
              title: '允许其他人插话',
              subtitle: 'allowOthers = ${n('allowOthers')}　关着时旁人说话完全不打断',
              trailing: _Same(dart: call.voiceprintOthers, native: native?['allowOthers']),
            ),
            SettingsTile(
              title: '唤醒也认声音',
              subtitle: 'wake = ${n('wake')}　和通话分开：唤醒判定频繁，误判代价不同',
              trailing: _Same(dart: call.voiceprintWake && call.voiceprint, native: native?['wake']),
            ),
            SettingsTile(
              title: '收音大小档位',
              subtitle: '${call.voiceprintMic.wire}　p=${call.voiceprintMic.percentile} '
                  'x${call.voiceprintMic.multiple} floor=${call.voiceprintMic.absoluteFloor}',
            ),
          ],
        ),

        if (native == null)
          SettingsSection(
            children: [
              SettingsTile(
                title: _loading ? '正在读原生状态…' : '读不到原生状态',
                subtitle: _loading ? null : '没有原生侧（桌面 / 测试环境），或模型加载失败',
                danger: !_loading,
              ),
            ],
          )
        else
          SettingsSection(
            title: '原始数据',
            children: [
              SettingsTile(
                title: 'voiceprintDescribe',
                subtitle: native.entries.map((e) => '${e.key}=${e.value}').join('\n'),
              ),
            ],
          ),

        SettingsSection(
          children: [
            SettingsTile(
              title: '同步到原生',
              subtitle: '两边值对不上时点一下；正常情况设置一改就会自动推',
              onTap: () async {
                await VoiceCallHost.pushVoiceprintNow(ref.container);
                await _refresh();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已推送，重新读取中')),
                  );
                }
              },
            ),
            SettingsTile(
              title: '复制全部',
              subtitle: '贴给别人看时用',
              onTap: () => _copy(context, call, profiles, native, acceptDart),
            ),
          ],
        ),
      ],
    );
  }

  String _verdictFor(double rms) {
    if (rms > -20) return '收得很响，正常档就行';
    if (rms > -35) return '略小，可用正常档';
    if (rms > -45) return '偏小，建议调「偏小」';
    if (rms > -55) return '很小，建议调「很小」';
    return '极小，调到「很小」也可能不够';
  }

  Future<void> _copy(
    BuildContext context,
    CallSettings call,
    List<VoiceProfile> profiles,
    Map<String, Object?>? native,
    double acceptDart,
  ) async {
    final lines = <String>[
      'build: ${AppInfo.buildLabel}',
      'version: ${AppInfo.displayVersion}',
      'profiles: ${profiles.length}',
      'mic: ${call.voiceprintMic.wire} p=${call.voiceprintMic.percentile} '
          'x=${call.voiceprintMic.multiple} floor=${call.voiceprintMic.absoluteFloor} '
          'fraction=${call.voiceprintMic.voicedFraction}',
      'dart.accept: $acceptDart',
      'probe: ${_probe == null ? "—" : "peak ${_probe!.peak.toStringAsFixed(1)} / rms ${_probe!.rms.toStringAsFixed(1)} dBFS"}',
      'native: ${native ?? "unavailable"}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制')));
    }
  }
}

/// 一行小字说明：这个参数是干什么的。诊断页到处都是参数，没有说明等于没写。
class _Explain extends StatelessWidget {
  const _Explain({required this.title, required this.subtitle, this.danger = false});

  final String title;
  final String subtitle;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: danger ? scheme.error : scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 3),
          Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
        ],
      ),
    );
  }
}

/// 设置算出来的值和原生实际用的值，一致就打勾，不一致就把两边都摆出来。
///
/// 不一致是本页最有价值的信号：说明配置没送到原生，问题不在算法。
class _Same extends StatelessWidget {
  const _Same({required this.dart, required this.native});

  final Object? dart;
  final Object? native;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (native == null) return Icon(Icons.help_outline, size: 18, color: scheme.outline);
    final a = dart?.toString();
    final b = native.toString();
    final same = a == b || (double.tryParse(a ?? '') != null && double.tryParse(b) != null &&
        ((double.tryParse(a!)! - double.parse(b)).abs() < 0.001));
    return Icon(
      same ? Icons.check_circle_outline : Icons.error_outline,
      size: 18,
      color: same ? scheme.primary : scheme.error,
    );
  }
}
