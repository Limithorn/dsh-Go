import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../nativemedia/speaker_gate_bridge.dart';
import '../../speech/voiceprint_store.dart';
import '../shell/page_frame.dart';
import '../settings/settings_widgets.dart';
import 'voice_level_meter.dart';

/// 录一个人的声音：三步，每步六秒，录完当场比对。
///
/// 为什么分三步：正常音量、稍远、有背景音，三种条件下各取一条，模板才覆盖得住
/// 真实使用时的差别。三步都在同一个采集配置下录（见原生 VoiceprintRecorder），
/// 与通话同分布——这一点比多录几秒更重要。
class VoiceprintEnrollPage extends ConsumerStatefulWidget {
  const VoiceprintEnrollPage({super.key});

  @override
  ConsumerState<VoiceprintEnrollPage> createState() => _VoiceprintEnrollPageState();
}

class _VoiceprintEnrollPageState extends ConsumerState<VoiceprintEnrollPage> {
  static const _seconds = 6;

  final _channel = VoiceprintChannel();

  int _step = 0;
  bool _recording = false;
  bool _busy = false;

  /// 最近一次录音存下来的 wav 路径。存进模板，好让以后能回放
  /// "当时到底录到了什么"。
  String? _lastClip;
  String? _hint;
  Timer? _ticker;
  int _left = _seconds;

  /// 录好的三段采样。
  final List<Float32List> _takes = [];

  /// 这次录的音源。
  ///
  /// 同一句话，通话里（AEC + 降噪）和唤醒时（不处理）拿到的是电平差十几 dB
  /// 的两段音频，向量对不上。想两种场景都认得出来，就各录一份：先用「通话」
  /// 录一次，再用「唤醒」录一次，得到两个 profile。
  VoiceProfileSource _source = VoiceProfileSource.call;

  /// 最近一次录音的实测值，用于校准阈值（也让人知道到底多小声）。
  RecordedAudio? _last;

  /// 录音进行中的实时电平与底噪（dBFS），喂给量表。
  /// 底噪还没量出来时保持 NaN，量表按 -70 画个默认起点。
  double _db = -120;
  double _floor = double.nan;

  /// 量表的刷新定时器：200ms 一次，比音频帧粗，但人眼够用。
  Timer? _meter;

  @override
  void dispose() {
    _ticker?.cancel();
    _meter?.cancel();
    if (_recording) unawaited(_channel.stopRecording());
    super.dispose();
  }

  String _stepText(L10n l10n) => switch (_step) {
    0 => l10n.speechVoiceprintStepOne,
    1 => l10n.speechVoiceprintStepTwo,
    _ => l10n.speechVoiceprintStepThree,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final canGoNext = _takes.length > _step;

    return AppPage.list(
      title: l10n.speechVoiceprintEnrollTitle,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_step + 1} / 3',
                style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 6),
              Text(_stepText(l10n), style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                l10n.speechVoiceprintStepHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        // 录哪个音源。放在最上面，因为它决定了这次录出来的模板"将来在哪种
        // 场景下认得准"，录完再改就晚了。
        SettingsSection(
          children: [
            SettingsSegmentTile<VoiceProfileSource>(
              key: const ValueKey('voiceprint-source'),
              title: '用哪一路声音',
              subtitle: _source == VoiceProfileSource.call
                  ? '通话里带降噪，录这份用来打断。想让叫名字也认得，再录一份「唤醒」'
                  : _source == VoiceProfileSource.wake
                  ? '唤醒时不降噪，录这份用来叫名字。打破断还需要一份「通话」'
                  : _source == VoiceProfileSource.unprocessed
                  ? '规范上要求系统别处理这段信号。Xperia 的 HAL 对第三方录音压得很低，'
                      '这一路最可能拿到正常电平'
                  : '不经任何处理，电平最高。一般用于对照，不建议当模板',
              segments: const [
                PillSegment(VoiceProfileSource.call, '通话'),
                PillSegment(VoiceProfileSource.wake, '唤醒'),
                PillSegment(VoiceProfileSource.unprocessed, '未处理'),
              ],
              selected: _source,
              // 正在录的时候不让改：这一段的向量得和哪一路对得上，中途换就乱了。
              onChanged: (_recording || _busy)
                  ? null
                  : (next) => setState(() => _source = next),
            ),
          ],
        ),
        SettingsSection(
          children: [
            // 量表在按钮上面：录的时候眼睛先落在这儿。
            if (_recording)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    VoiceLevelMeter(db: _db, floor: _floor, needed: _minSnr),
                    const SizedBox(height: 6),
                    Text(
                      (_db - (_floor.isNaN ? -70 : _floor)) >= _minSnr
                          ? l10n.speechVoiceprintGood
                          : l10n.speechVoiceprintTooQuiet,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: (_db - (_floor.isNaN ? -70 : _floor)) >= _minSnr
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            SettingsTile(
              key: const ValueKey('voiceprint-record'),
              title: _recording ? l10n.speechVoiceprintListening : l10n.speechVoiceprintStart,
              subtitle: _recording ? '$_left s' : null,
              trailing: _recording
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2, value: _left / _seconds),
                    )
                  : null,
              onTap: _busy ? null : _toggleRecord,
            ),
            if (_hint case final hint?)
              SettingsTile(
                key: const ValueKey('voiceprint-hint'),
                title: hint,
                danger: true,
              ),
            // 实测值：响度够不够、会不会太吵，一眼看清，不用猜。
            if (_last case final last?)
              SettingsTile(
                key: const ValueKey('voiceprint-meter'),
                title: l10n.speechVoiceprintMeter(
                  (last.milliseconds / 1000).toStringAsFixed(1),
                  last.loudness.toStringAsFixed(0),
                  last.noisiness.toStringAsFixed(2),
                ),
              ),
            if (canGoNext && _step < 2)
              SettingsTile(
                key: const ValueKey('voiceprint-next'),
                title: l10n.speechVoiceprintNext,
                onTap: _busy ? null : () => setState(() => _step += 1),
              ),
            if (_takes.length == 3)
              SettingsTile(
                key: const ValueKey('voiceprint-save'),
                title: _busy ? l10n.speechVoiceprintSaving : l10n.speechVoiceprintNext,
                onTap: _busy ? null : _finish,
              )
            // 这一段没过：说清楚"再来一次"，否则用户会以为程序卡住了。
            else if (_last != null && _hint != null)
              SettingsTile(
                key: const ValueKey('voiceprint-retry'),
                title: l10n.speechVoiceprintRetryThis,
                subtitle: l10n.speechVoiceprintRetryThisHint(_takes.length, 3 - _takes.length),
                onTap: _recording || _busy ? null : () => unawaited(_toggleRecord()),
              ),
          ],
        ),
        SettingsSection(
          children: [
            SettingsTile(
              key: const ValueKey('voiceprint-cancel'),
              title: l10n.speechVoiceprintCancel,
              onTap: _busy ? null : () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      await _stop();
      return;
    }
    setState(() {
      _hint = null;
      // 上一段的实测值和失败原因一起清掉。
      //
      // 只清 _hint 会漏出一个死状态：_last 还在、「重录这段」那条依赖
      // `_last != null && _hint != null`，_hint 一清就不显示了；而「下一步」
      // 要 _takes.length > _step、「保存」要 _takes.length == 3，两个都不成立。
      // 三个按钮全不见，界面上没有任何可点的东西——就是"卡死"。
      _last = null;
      _left = _seconds;
    });
    final ok = await _channel.startRecording(source: _source);
    if (!ok) {
      if (mounted) setState(() => _hint = context.l10n.speechVoiceprintUnsupported);
      return;
    }
    if (!mounted) return;
    setState(() {
      _recording = true;
      _db = -120;
      _floor = double.nan;
    });
    _meter?.cancel();
    _meter = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (!mounted) return;
      final next = await _channel.level();
      if (mounted) {
        setState(() {
          _db = next.db;
          _floor = next.floor;
        });
      }
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = (_left - 1).clamp(0, _seconds));
      if (_left <= 0) unawaited(_stop());
    });
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    _meter?.cancel();
    final result = await _channel.stopRecording();
    if (!mounted) return;
    setState(() => _recording = false);
    if (result == null) {
      setState(() => _hint = context.l10n.speechVoiceprintTooShort);
      return;
    }
    _lastClip = result.clipPath;
    final problem = _problemWith(result, context.l10n);
    if (problem != null) {
      setState(() {
        _last = result;
        _hint = problem;
      });
      return;
    }
    setState(() {
      _last = result;
      _hint = null;
      // 已经收满三段时，这一遍是"重录"：换掉当前这一步的那一条，不是往后加。
      // 早先这里只是 add，满了之后变成四条，界面上"保存"按钮就再也不出现了——
      // 表现就是"重录之后没有下一步"。
      if (_takes.length >= 3) {
        _takes[_step.clamp(0, 2)] = result.samples;
      } else {
        _takes.add(result.samples);
      }
    });
  }

  /// 这段能不能用。
  ///
  /// 判"够不够响"用的是**比环境底噪高多少**，不是绝对音量：安静房间底噪 -65、
  /// 说话 -48 就够（高出 17dB）；嘈杂环境底噪 -45，同样的 -48 等于没说清。
  /// 固定一条绝对值，永远只对一种环境成立。
  String? _problemWith(RecordedAudio result, L10n l10n) {
    if (result.milliseconds < 3000) return l10n.speechVoiceprintTooShort;
    // 底噪量不出来（开头就是人声）时不卡这一条，免得把人挡在门外。
    if (!result.floor.isNaN && result.snr < _minSnr) return l10n.speechVoiceprintTooQuiet;
    // 底噪段的起伏：正常环境 0.3–1.2，超过 2 才算真吵。
    if (result.noisiness > 2.0) return l10n.speechVoiceprintTooNoisy;
    return null;
  }

  /// 说话要比环境高出多少分贝才算"说清楚了"。
  ///
  /// 从 12 放到 8：实测正常说话在 14 上下，12 太贴边，稍微轻一点就被挡——
  /// 表现为"录完第三段没有下一步"，人以为程序卡住了。
  static const _minSnr = 8.0;

  /// 三段录音彼此至少要有多像。
  ///
  /// 0.40 是"明显是同一个人"的下限：同一人不同句子通常 0.6–0.8，
  /// 环境差、句子短的时候会掉到 0.5 上下。低于 0.4 多半真有一遍说坏了。
  static const _minConsistency = 0.40;

  /// 把这一轮的三段向量和两两相似度写到外部存储，供排查。
  ///
  /// 只写一份，覆盖上一次——这是诊断用的临时产物，不是数据。
  Future<void> _dumpForDiagnosis(List<Float32List> vectors, double worst) async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      final scores = <String>[];
      for (var i = 0; i < vectors.length; i++) {
        for (var j = i + 1; j < vectors.length; j++) {
          scores.add('"$i-$j": ${VoiceprintStore.cosine(vectors[i], vectors[j]).toStringAsFixed(4)}');
        }
      }
      final body = '{\n'
          '  "takes": ${vectors.length},\n'
          '  "worst": ${worst.toStringAsFixed(4)},\n'
          '  "pairwise": {${scores.join(', ')}},\n'
          '  "vectors": [${vectors.map((v) => v.join(',')).join(',\n    ')}]\n'
          '}';
      await File('${dir.path}/voiceprint-diagnosis.json').writeAsString(body, flush: true);
    } on Object {
      // 诊断写不出去不影响录入本身。
    }
  }

  /// 三段里最不像平均模板的是第几条。
  int _worstIndex(Float32List merged, List<Float32List> vectors) {
    var worst = 1.0;
    var at = 0;
    for (var i = 0; i < vectors.length; i++) {
      final cos = VoiceprintStore.cosine(merged, vectors[i]);
      if (cos < worst) {
        worst = cos;
        at = i;
      }
    }
    return at;
  }

  Future<void> _finish() async {
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _hint = null;
    });
    try {
      // 三段各算一条向量，取平均再归一化——比只用一段稳。
      final vectors = <Float32List>[];
      for (final take in _takes) {
        final v = await _channel.embed(take);
        if (v != null && v.isNotEmpty) vectors.add(v);
      }
      if (!mounted) return;
      if (vectors.isEmpty) {
        setState(() => _hint = l10n.speechVoiceprintSelfCheckFailed);
        return;
      }
      final merged = _average(vectors);

      // 自检：三段里最不像平均模板的那条，差太多说明彼此不一致。
      var worst = 1.0;
      for (final v in vectors) {
        final cos = VoiceprintStore.cosine(merged, v);
        if (cos < worst) worst = cos;
      }
      // 门槛从 0.55 放到 0.40：同一个人说不同的句子，余弦通常 0.6–0.8，
      // 但录的是短句、环境又有起伏时，0.5 上下很常见。0.55 会把人挡回去，
      // 而且旧代码挡回去之后不让人重录——两层叠起来就是"卡在第三步"。
      // 无论过不过，都把这几个数写到外部存储：出问题时不用再靠猜。
      unawaited(_dumpForDiagnosis(vectors, worst));
      if (worst < _minConsistency) {
        // 三段彼此差太多：多半是有一遍说走了音或环境变了。
        // 把不满的那一段挑出来，退回那一步让人重录——不能只是报错然后卡死。
        // 顺带把分数写出来：不写就分不清"是阈值太严"还是"音频真的不行"。
        if (mounted) {
          setState(() {
            _busy = false;
            _hint = l10n.speechVoiceprintSelfCheckFailedNum(
              worst.toStringAsFixed(2),
              _minConsistency.toStringAsFixed(2),
            );
            final worstIndex = _worstIndex(merged, vectors);
            _takes.removeAt(worstIndex.clamp(0, _takes.length - 1));
            // _step 永远落在 0..2：它既是标题里的"第几段"，也是重录时的替换下标。
            _step = _takes.length.clamp(0, 2);
          });
        }
        return;
      }

      // 去重：和已有模板太像就别再存一条。
      final existing = ref.read(voiceprintProfilesProvider).value ?? const <VoiceProfile>[];
      final closest = VoiceprintStore.closest(existing, merged);
      VoiceProfile? replacing;
      if (closest.match != null && closest.score >= VoiceprintStore.duplicateAt) {
        final match = closest.match!;
        final name = match.label.isNotEmpty ? match.label : '#${existing.indexOf(match) + 1}';
        final yes = await _askDuplicate(l10n.speechVoiceprintDuplicateHint(name));
        if (!mounted) return;
        if (yes != true) {
          setState(() => _busy = false);
          return;
        }
        replacing = match;
      }

      final notifier = ref.read(voiceprintProfilesProvider.notifier);
      if (replacing != null) await notifier.remove(replacing.id);
      await notifier.add(
        VoiceProfile(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          createdAt: DateTime.now(),
          vector: merged,
          source: _source,
          clipPath: _lastClip ?? '',
        ),
      );
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _askDuplicate(String hint) => showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(context.l10n.speechVoiceprintDuplicate),
      content: Text(hint),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(context.l10n.speechVoiceprintCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(context.l10n.speechVoiceprintOverwrite),
        ),
      ],
    ),
  );

  static Float32List _average(List<Float32List> vectors) {
    final dim = vectors.first.length;
    final sum = List<double>.filled(dim, 0);
    for (final v in vectors) {
      for (var i = 0; i < dim && i < v.length; i++) {
        sum[i] += v[i];
      }
    }
    var norm = 0.0;
    for (final v in sum) {
      norm += v * v;
    }
    norm = norm <= 0 ? 1 : _sqrt(norm);
    final out = Float32List(dim);
    for (var i = 0; i < dim; i++) {
      out[i] = sum[i] / norm;
    }
    return out;
  }

  static double _sqrt(double v) {
    if (v <= 0) return 0;
    var x = v;
    for (var i = 0; i < 40; i++) {
      x = 0.5 * (x + v / x);
    }
    return x;
  }
}
