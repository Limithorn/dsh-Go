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

/// 一次量测的结果（三种配置各一次）。
class _Matrix {
  _Matrix({required this.vcNoAec, required this.vcAec, required this.vrNoAec, required this.sdk});

  final double vcNoAec;
  final double vcAec;
  final double vrNoAec;
  final int sdk;

  double get cut => (vcNoAec <= -900 || vcAec <= -900) ? double.nan : vcNoAec - vcAec;
}

class _AecDiagnosticsPageState extends ConsumerState<AecDiagnosticsPage> {
  static const _channel = MethodChannel('dsh/speech');

  bool _busy = false;
  Map<Object?, Object?>? _report;
  _Matrix? _matrix;
  String? _note;

  @override
  void initState() {
    super.initState();
    unawaited(_loadReport());
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
    final m = await _channel.invokeMapMethod<Object?, Object?>('aecProbe', {'ms': 1200});
    if (!mounted) return;
    if (m == null || m['error'] != null) {
      setState(() {
        _busy = false;
        _note = '${m?['error'] ?? '量不出来'}';
      });
      return;
    }
    setState(() {
      _busy = false;
      _matrix = _Matrix(
        vcNoAec: (m['vcNoAec'] as num?)?.toDouble() ?? -999,
        vcAec: (m['vcAec'] as num?)?.toDouble() ?? -999,
        vrNoAec: (m['vrNoAec'] as num?)?.toDouble() ?? -999,
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
            title: '结果（dBFS）',
            children: [
              SettingsTile(title: '通话音源 · 不开 AEC', subtitle: '回声原本的样子', trailing: Text(_db(m.vcNoAec))),
              SettingsTile(title: '通话音源 · 开 AEC', subtitle: 'AEC 削过之后', trailing: Text(_db(m.vcAec))),
              SettingsTile(title: '识别音源 · 不开 AEC', subtitle: '不降噪，电平最高', trailing: Text(_db(m.vrNoAec))),
              SettingsTile(
                title: m.cut.isNaN ? 'AEC 削掉多少：量不出' : 'AEC 削掉 ${m.cut.toStringAsFixed(1)} dB',
                subtitle: m.cut.isNaN
                    ? null
                    : (m.cut < 1
                          ? '几乎没削：AEC 没起作用'
                          : (m.cut > 6 ? '削得明显，AEC 有效' : '削得不多，可能不够')),
                trailing: Icon(
                  m.cut.isNaN
                      ? Icons.help_outline
                      : (m.cut >= 1 ? Icons.check_circle_outline : Icons.error_outline),
                  size: 20,
                  color: m.cut.isNaN
                      ? scheme.onSurfaceVariant
                      : (m.cut >= 1 ? scheme.primary : scheme.error),
                ),
              ),
            ],
          ),
        if (_matrix case final m? when m.cut >= 1)
          SettingsSection(
            children: [
              SettingsTile(
                title: '结论',
                subtitle:
                    'AEC 在这台机器上是有效的（削掉 ${m.cut.toStringAsFixed(1)} dB）。'
                    '如果外放还是被自己打断，问题不在 AEC，而在声纹判定这一环——'
                    '去「实景测试」看播放时的分数是不是偏高，必要时把插话灵敏度往'
                    '「很难被打断」调，或者调高识别灵敏度的严格度。',
              ),
            ],
          ),
        if (_matrix case final m? when m.cut < 1 && !m.cut.isNaN)
          SettingsSection(
            children: [
              SettingsTile(
                title: '结论',
                subtitle:
                    'AEC 基本没在削（差 ${m.cut.toStringAsFixed(1)} dB）。外放时自己的声音会'
                    '原样进麦克风，被声纹判成"你自己"——这就是自打断的来源。\n'
                    '可以考虑把「通话收音」换成"识别（不降噪）"：那一路电平高得多，'
                    '但同样没有回声消除，需要靠插话灵敏度去挡。',
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

  Widget _layer(String name, bool ok, String detail) => SettingsTile(
    title: name,
    subtitle: detail.isEmpty ? null : detail,
    trailing: Icon(
      ok ? Icons.check_circle_outline : Icons.remove_circle_outline,
      size: 20,
      color: ok ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outline,
    ),
  );

  static String _db(double v) => v <= -900 ? '打不开' : v.toStringAsFixed(1);
}
