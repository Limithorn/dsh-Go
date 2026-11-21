import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../speech/speech_settings.dart';
import '../shell/page_frame.dart';
import 'settings_widgets.dart';

/// AEC 诊断：回声消除到底开没开，断在哪一层。
///
/// 为什么值得单独一页：`AcousticEchoCanceler.isAvailable()` 说"支持"，
/// 不等于回声被消掉了。真正决定成败的是四层，而且 **Android 13 和 14
/// 断的地方不一样**：
///
/// 1. ROM 声称支持
/// 2. 拿得到 effect 对象
/// 3. setEnabled 后读回 enabled == true
/// 4. 音源本身带 HAL 级 AEC（VOICE_COMMUNICATION 自带）
///
/// 13 上一般是第 3 层成功；14 上效果器常被挪进 audio HAL，第 2、3 层
/// 失败但第 4 层仍然有效。只看"开没开"会把 14 误判成坏的。
class AecDiagnosticsPage extends ConsumerStatefulWidget {
  const AecDiagnosticsPage({super.key});

  @override
  ConsumerState<AecDiagnosticsPage> createState() => _AecDiagnosticsPageState();
}

/// 一种配置的回声残留。
///
/// [leak] = 播放时电平 − 静默时电平。这是唯一有意义的量：AEC 拿正在播放
/// 的音频当参考去减，不放东西时它没有参考，测出来的只是底噪。
class _One {
  _One({required this.playing, required this.silent, required this.leak, required this.usable, this.aecOn});

  final double playing;
  final double silent;
  final double leak;
  final bool usable;
  final bool? aecOn;

  bool get ok => usable && leak < 10;
  bool get bad => usable && leak >= 22;
}

class _Echo {
  _Echo({required this.vcNoAec, required this.vcAec, required this.vrNoAec, required this.sdk});

  final _One? vcNoAec;
  final _One vcAec;
  final _One vrNoAec;
  final int sdk;

  /// AEC 实际减少了多少回声：不开的漏量减去开的漏量。
  double? get gain {
    final a = vcNoAec;
    if (a == null || !a.usable || !vcAec.usable) return null;
    return a.leak - vcAec.leak;
  }
}

/// 一次音源选择，对应原生 `MicSource.Pick`。
///
/// 为什么要在这里显示：auto 会**自己换路**，所以"设置里选了自动"回答不了
/// "这次到底收的哪一路"。两条路径（通话 / 实景测试）必须收同一路声音，分数
/// 才可比——这一栏就是拿来看这件事成不成立的。
class _Pick {
  _Pick({
    required this.requested,
    required this.chosen,
    required this.reason,
    required this.at,
    this.vc,
    this.vr,
    this.mic,
    this.delta,
  });

  final String requested;
  final String chosen;
  final String reason;
  final int at;

  /// 自动判断时量到的峰值（dBFS）；手动指定档位时不量，是 null。
  final double? vc;
  final double? vr;
  final double? mic;
  final double? delta;

  static _Pick? of(Object? raw) {
    if (raw is! Map) return null;
    return _Pick(
      requested: '${raw['requested'] ?? '—'}',
      chosen: '${raw['chosen'] ?? '—'}',
      reason: '${raw['reason'] ?? ''}',
      at: (raw['at'] as num?)?.toInt() ?? 0,
      vc: (raw['vc'] as num?)?.toDouble(),
      vr: (raw['vr'] as num?)?.toDouble(),
      mic: (raw['mic'] as num?)?.toDouble(),
      delta: (raw['delta'] as num?)?.toDouble(),
    );
  }
}

class _AecDiagnosticsPageState extends ConsumerState<AecDiagnosticsPage> {
  static const _channel = MethodChannel('dsh/speech');

  bool _busy = false;
  Map<Object?, Object?>? _report;
  _Echo? _matrix;
  String? _note;

  /// 音源：两条路径各自最近一次的选择 + 手动量的那一次。
  _Pick? _micCall;
  _Pick? _micScreen;
  _Pick? _micProbe;
  double _swapDb = 20;
  bool _micBusy = false;
  bool _micRunning = false;
  String? _micNote;

  @override
  void initState() {
    super.initState();
    unawaited(_loadReport());
    unawaited(_loadMic());
  }

  Future<void> _loadMic() async {
    Map<Object?, Object?>? r;
    try {
      r = await _channel.invokeMapMethod<Object?, Object?>('micSourceReport');
    } on PlatformException {
      // 旧版原生没有这个方法：这一栏整块不显示，别的照旧。
      return;
    }
    if (!mounted || r == null) return;
    _applyMic(r);
  }

  void _applyMic(Map<Object?, Object?> r) {
    setState(() {
      _micCall = _Pick.of(r['call']);
      _micScreen = _Pick.of(r['screen']);
      _micProbe = _Pick.of(r['probe']);
      _swapDb = (r['swapDb'] as num?)?.toDouble() ?? _swapDb;
      _micRunning = r['busy'] == true;
    });
  }

  /// 手动量一遍：三条音源各录 1.5 秒，返回量到的峰值和"自动会选哪一路"。
  Future<void> _probeMic() async {
    setState(() {
      _micBusy = true;
      _micNote = null;
    });
    Map<Object?, Object?>? m;
    try {
      m = await _channel.invokeMapMethod<Object?, Object?>('micSourceProbe');
    } on PlatformException {
      m = null;
    }
    if (!mounted) return;
    if (m == null) {
      setState(() {
        _micBusy = false;
        _micNote = '量不出来（旧版原生不支持这个量测）';
      });
      return;
    }
    final error = m['error'];
    if (error != null) {
      setState(() {
        _micBusy = false;
        _micNote = '$error';
      });
      return;
    }
    final pick = _Pick.of(m);
    setState(() {
      _micBusy = false;
      _micProbe = pick;
    });
    unawaited(_loadMic());
  }

  Future<void> _loadReport() async {
    final r = await _channel.invokeMapMethod<Object?, Object?>('aecReport');
    if (!mounted) return;
    setState(() => _report = r);
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _note = null;
      _matrix = null;
    });
    // 会放一段扫频音，音量拉到最大，持续约 8 秒。
    final m = await _channel.invokeMapMethod<Object?, Object?>('aecEcho', {'ms': 1500});
    if (!mounted) return;
    if (m == null || m['error'] != null) {
      setState(() {
        _busy = false;
        _note = '${m?['error'] ?? '量不出来'}';
      });
      return;
    }
    _One? one(Object? raw) {
      if (raw is! Map) return null;
      final playing = (raw['playing'] as num?)?.toDouble() ?? -999;
      final silent = (raw['silent'] as num?)?.toDouble() ?? -999;
      final leak = (raw['leak'] as num?)?.toDouble() ?? -999;
      return _One(
        playing: playing,
        silent: silent,
        leak: leak,
        usable: raw['usable'] == true && leak > -500,
        aecOn: raw['aecOn'] as bool?,
      );
    }

    final vcAec = one(m['vcAec']);
    final vr = one(m['vrNoAec']);
    if (vcAec == null || vr == null) {
      setState(() {
        _busy = false;
        _note = '量测结果不完整';
      });
      return;
    }
    setState(() {
      _busy = false;
      _matrix = _Echo(
        vcNoAec: one(m['vcNoAec']),
        vcAec: vcAec,
        vrNoAec: vr,
        sdk: (m['sdk'] as num?)?.toInt() ?? 0,
      );
    });
    unawaited(_loadReport());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final call = ref.watch(callSettingsProvider);
    final r = _report;
    final has = r != null && r.isNotEmpty;

    final available = r?['available'] == true;
    final created = r?['created'] == true;
    final confirmed = r?['enabledConfirmed'] == true;
    final halAec = r?['sourceHasHalAec'] == true;
    final effective = r?['effective'] == true;
    final source = '${r?['source'] ?? '—'}';
    final sdk = (r?['sdk'] as num?)?.toInt() ?? 0;

    return AppPage.list(
      title: '回声消除诊断',
      subtitle: const Text('AEC 到底开没开，断在哪一层'),
      children: [
        SettingsSection(
          title: '这次采集',
          children: [
            if (!has)
              const SettingsTile(
                title: '还没有采集记录',
                subtitle: '先打一通电话，或者回上一页跑一次实景测试，再回来看',
              )
            else ...[
              SettingsTile(
                title: '${r['summary'] ?? '—'}',
                subtitle: '${r['note'] ?? ''}',
                trailing: Icon(
                  effective ? Icons.check_circle_outline : Icons.error_outline,
                  size: 20,
                  color: effective ? scheme.primary : scheme.error,
                ),
              ),
              SettingsTile(
                title: '音源 ${r['source'] ?? '—'}',
                subtitle: halAec
                    ? 'VOICE_COMMUNICATION 自带系统级 AEC：哪怕 AudioEffect 层失败，回声通常仍被消过'
                    : '这一路不带系统级 AEC。换成通话音源，或者接受回声会漏进来',
              ),
            ],
          ],
        ),
        if (has)
          SettingsSection(
            title: '逐层',
            children: [
              _layer(
                '① ROM 声称支持 AEC',
                available,
                available ? '是' : '否——这台机器的音频栈没暴露 AcousticEchoCanceler',
              ),
              _layer(
                '② 拿到 effect 对象',
                created,
                created
                    ? '是'
                    : (available
                          ? '否——16 进制地址拿到了但 create 返回 null，效果器通常在 HAL 里'
                          : '没试——上一层就没过'),
              ),
              _layer(
                '③ 真启用（读回 enabled）',
                confirmed,
                confirmed
                    ? '是'
                    : (created
                          ? '否——create 成功但 enabled 读回 false，这是 Android 14 的典型表现'
                          : '没试——上一层就没过'),
              ),
              _layer(
                '④ 音源自带 HAL 级 AEC',
                halAec,
                halAec ? '是（$source）' : '否（$source 不保证有 AEC）',
              ),
            ],
          ),
        if (has && (r['nsAvailable'] != null))
          SettingsSection(
            title: '降噪（NS）',
            children: [
              _layer('ROM 支持', r['nsAvailable'] == true, ''),
              _layer('拿到对象', r['nsCreated'] == true, ''),
              _layer('真启用', r['nsEnabledConfirmed'] == true, ''),
            ],
          ),
        SettingsSection(
          title: '音源（通话和实景测试同一个设置）',
          children: [
            SettingsTile(
              key: const ValueKey('mic-source-setting'),
              title: '设置：${call.callMicSource.label}',
              subtitle: '自动时按实测电平换路：识别比通话高 ${_swapDb.toStringAsFixed(0)} dB 以上才换。'
                  '实景测试不再有自己的音源开关，两边收的是同一路。',
            ),
            _pickRow('通话最近一次', _micCall),
            _pickRow('实景测试最近一次', _micScreen),
            if (_micCall case final a?)
              if (_micScreen case final b?)
                SettingsTile(
                  title: a.chosen == b.chosen
                      ? '两边收的是同一路：${a.chosen}'
                      : '两边不是同一路：通话 ${a.chosen}，实景测试 ${b.chosen}',
                  subtitle: a.chosen == b.chosen
                      ? '同一路声音，实景测试的分数才能和通话互相印证'
                      : '改完设置后各跑一次，让两边用同一套判断重新选一遍',
                  trailing: Icon(
                    a.chosen == b.chosen ? Icons.check_circle_outline : Icons.error_outline,
                    size: 20,
                    color: a.chosen == b.chosen ? scheme.primary : scheme.error,
                  ),
                ),
            SettingsTile(
              key: const ValueKey('mic-source-probe'),
              title: _micBusy ? '正在量…' : '量一遍音源（约 5 秒）',
              subtitle: '三条音源各录 1.5 秒，报峰值和"自动会选哪一路"。保持安静，别说话',
              onTap: _micBusy || _micRunning ? null : _probeMic,
            ),
            if (_micRunning)
              const SettingsTile(
                title: '麦克风正被通话或实景测试占用',
                subtitle: '先停掉，再回来量',
              ),
            if (_micNote case final n?) SettingsTile(title: n, danger: true),
            if (_micProbe case final p?) _pickRow('手量结果', p),
          ],
        ),
        SettingsSection(
          title: '实测',
          children: [
            SettingsTile(
              key: const ValueKey('aec-probe'),
              title: _busy ? '量测中…' : '量一遍（约 4 秒）',
              subtitle: '同一段静默，三种配置各录一次。保持安静，别说话',
              onTap: _busy ? null : _probe,
            ),
            if (_note case final n?) SettingsTile(title: n, danger: true),
          ],
        ),
        if (_matrix case final m?)
          SettingsSection(
            title: '结果',
            children: [
              _row('通话音源 · 不开 AEC', m.vcNoAec, 'AEC 不介入，回声原样进来'),
              _row('通话音源 · 开 AEC', m.vcAec, 'AEC 介入之后'),
              _row('识别音源 · 不开 AEC', m.vrNoAec, '不降噪的一路，作对照'),
            ],
          ),
        if (_matrix case final m? when m.gain != null)
          SettingsSection(
            title: 'AEC 起了多少作用',
            children: [
              SettingsTile(
                title: '回声减少 ${m.gain!.toStringAsFixed(1)} dB',
                subtitle: m.gain! < 3
                    ? '几乎没减少——AEC 在这台机器上没起作用'
                    : (m.gain! < 10
                          ? '减少了一点，但不够：外放时自己播的声音仍会明显漏回来'
                          : '减少明显，AEC 在工作'),
                trailing: Icon(
                  m.gain! < 3 ? Icons.error_outline : Icons.check_circle_outline,
                  size: 20,
                  color: m.gain! < 3 ? scheme.error : scheme.primary,
                ),
              ),
            ],
          ),
        if (_matrix case final m?)
          SettingsSection(
            children: [
              SettingsTile(
                title: '怎么读',
                subtitle:
                    '「漏」是播放时的电平减去静默时的电平——那是真正漏进麦克风的回声。\n'
                    '小于 10 dB 说明基本没漏；大于 22 dB 说明等于没消。\n'
                    '${m.gain == null ? '没测出可用的对比：可能某一次没采到声音。' : ''}',
              ),
            ],
          ),
        SettingsSection(
          children: [
            SettingsTile(
              title: '当前设置',
              subtitle: '通话收音 ${call.callMicSource.label} · '
                  '识别灵敏度 ${call.voiceprintLevel.wire} · '
                  '系统 Android $sdk',
            ),
          ],
        ),
      ],
    );
  }

  /// 一行音源选择：选了哪一路、依据、量到的峰值、什么时候。
  Widget _pickRow(String label, _Pick? p) {
    if (p == null) return SettingsTile(title: label, subtitle: '还没有记录', trailing: const Text('—'));
    final scheme = Theme.of(context).colorScheme;
    final lines = <String>[
      if (p.reason.isNotEmpty) p.reason,
      if (p.vc != null && p.vr != null)
        '实测峰值：通话 ${_db(p.vc!)} / 识别 ${_db(p.vr!)}'
            '${p.mic == null ? '' : ' / 原始麦 ${_db(p.mic!)}'} dBFS'
            '${p.delta == null ? '' : '，差 ${p.delta!.toStringAsFixed(1)} dB'}',
      if (p.at > 0) '量于 ${_clock(p.at)}',
    ];
    final swapped = p.requested == 'auto' && p.chosen == 'VOICE_RECOGNITION';
    return SettingsTile(
      title: '$label：${p.chosen}',
      subtitle: lines.isEmpty ? null : lines.join('\n'),
      trailing: Icon(
        swapped ? Icons.swap_horiz : Icons.chevron_right,
        size: 20,
        color: swapped ? scheme.primary : scheme.outline,
      ),
    );
  }

  static String _clock(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Widget _layer(String name, bool ok, String detail) => SettingsTile(
    title: name,
    subtitle: detail.isEmpty ? null : detail,
    trailing: Icon(
      ok ? Icons.check_circle_outline : Icons.remove_circle_outline,
      size: 20,
      color: ok ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline,
    ),
  );

  static String _db(double v) => switch (v) {
    <= -997 => '没采到',
    <= -900 => '打不开',
    _ => v.toStringAsFixed(1),
  };

  /// 一行结果：漏量 + 播放/静默两个原始值。
  Widget _row(String name, _One? o, String hint) {
    final scheme = Theme.of(context).colorScheme;
    if (o == null) {
      return SettingsTile(title: name, subtitle: '没测到', trailing: const Text('—'));
    }
    if (!o.usable) {
      return SettingsTile(
        title: name,
        subtitle: '没采到有效声音（播放 ${_db(o.playing)} / 静默 ${_db(o.silent)}）',
        trailing: const Text('—'),
      );
    }
    return SettingsTile(
      title: name,
      subtitle: '$hint　播放 ${_db(o.playing)} / 静默 ${_db(o.silent)}',
      trailing: Text(
        '漏 ${o.leak.toStringAsFixed(1)}',
        style: TextStyle(
          color: o.bad ? scheme.error : (o.ok ? scheme.primary : scheme.onSurfaceVariant),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
