import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../nativemedia/speaker_gate_bridge.dart';
import '../../speech/speech_audio.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voiceprint_log.dart';
import '../../speech/voiceprint_store.dart';
import '../shell/page_frame.dart';
import '../settings/settings_widgets.dart';

/// 声纹诊断：**录一句，立刻看这句被判成什么。**
///
/// 为什么要能当场试：通话里验证一次要等她开口、你要挑时机插话、还得猜是
/// "模型认错"还是"当时没人在说话"。在这里录一句，输入是确定的，分数也就
/// 有了确定的意思——这比任何日志都直接。
///
/// 用法：点「录一句试试」，说一句完整的话。看到分数后就能判断阈值该往上还是往下：
///  - 你自己说，分数低于「判自己人的线」→ 阈值定高了，你会被挡在门外；
///  - 旁人（或换个距离/压低声音）说，分数高于「判旁人的线」→ 阈值定低了。
///
/// 通话里每次开口的记录也留在下面，用来看真实场景和这里差多少。
class VoiceprintDiagnosticsPage extends ConsumerStatefulWidget {
  const VoiceprintDiagnosticsPage({super.key, this.embedded = false});

  /// 装进 Tab 里：不画大标题，只留列表体。
  final bool embedded;

  @override
  ConsumerState<VoiceprintDiagnosticsPage> createState() => _VoiceprintDiagnosticsPageState();
}

class _VoiceprintDiagnosticsPageState extends ConsumerState<VoiceprintDiagnosticsPage> {
  final _channel = VoiceprintChannel();

  bool _recording = false;
  bool _busy = false;
  String? _note;

  /// 刚录这一句的结果。
  ({double score, VoiceprintKind kind, double? short, double? suggest})? _last;

  /// 建议门槛比实测分低多少。
  ///
  /// 0.08：同一句"是我"，换个句子、换个距离，实测分会上下浮动这么大
  /// （看这一页下面的判定记录就知道）。贴着实测分设门槛，下一句就被挡。
  static const _suggestMargin = 0.08;

  @override
  void dispose() {
    if (_recording) unawaited(_channel.stopRecording());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final log = ref.watch(voiceprintLogProvider);
    final profiles = ref.watch(voiceprintProfilesProvider).value ?? const <VoiceProfile>[];
    final settings = ref.watch(callSettingsProvider);
    final cut = _cutoffs(settings, profiles.length);
    final theme = Theme.of(context);
    final canTry = profiles.isNotEmpty && !_busy && !_recording;

    return AppPage.list(
      showLargeTitle: !widget.embedded,
      title: l10n.speechVoiceprintDiagnostics,
      children: [
        // 现场试一句：整页最主要的东西，放在最上面。
        SettingsSection(
          footer: Text(l10n.speechVoiceprintDiagTryHint),
          children: [
            if (profiles.isEmpty)
              SettingsTile(title: l10n.speechVoiceprintDiagNeedProfile)
            else ...[
              SettingsTile(
                key: const ValueKey('diag-try'),
                title: _recording
                    ? l10n.speechVoiceprintDiagTryRecording
                    : (_busy ? l10n.speechVoiceprintDiagSelfCheckRunning : l10n.speechVoiceprintDiagTry),
                subtitle: _recording ? null : l10n.speechVoiceprintDiagSelfMin(
                  '${cut.accept.toStringAsFixed(2)} / ${cut.reject.toStringAsFixed(2)}',
                ),
                trailing: _recording || _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: canTry ? _tryOne : null,
              ),
              if (_last case final last?) ...[
                SettingsTile(
                  key: const ValueKey('diag-try-verdict'),
                  title: l10n.speechVoiceprintDiagTryResult(_name(last.kind, l10n)),
                  danger: last.kind != VoiceprintKind.you,
                  trailing: Text(
                    last.score.toStringAsFixed(3),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: last.kind == VoiceprintKind.you
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                SettingsTile(
                  title: l10n.speechVoiceprintDiagTryScore(
                    last.score.toStringAsFixed(3),
                    cut.accept.toStringAsFixed(2),
                    cut.reject.toStringAsFixed(2),
                  ),
                  subtitle: last.short == null
                      ? null
                      : '整段 ${last.score.toStringAsFixed(3)} · 只用最后 600ms ${last.short!.toStringAsFixed(3)}',
                ),
              ],
              if (_note case final note?) SettingsTile(title: note, danger: true),
            ],
          ],
        ),

        // 通话里记下来的判定，用来对照真实场景。
        if (log.isNotEmpty) ...[
          SettingsSection(
            title: l10n.speechVoiceprintDiagListTitle,
            children: [
              for (final s in [...log]..sort((a, b) => b.score.compareTo(a.score)))
                SettingsTile(
                  title: '${s.score.toStringAsFixed(3)}  ${_name(s.kind, l10n)}',
                  subtitle: '${_time(s.at)}${s.over ? ' · ${l10n.speechVoiceprintDiagOver}' : ''}',
                  trailing: Icon(
                    s.kind == VoiceprintKind.you
                        ? Icons.check_circle_outline
                        : s.kind == VoiceprintKind.other
                        ? Icons.cancel_outlined
                        : Icons.help_outline,
                    size: 20,
                    color: s.kind == VoiceprintKind.you
                        ? theme.colorScheme.primary
                        : s.kind == VoiceprintKind.other
                        ? theme.colorScheme.error
                        : theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
          SettingsSection(
            children: [
              SettingsTile(
                key: const ValueKey('diag-clear'),
                title: l10n.speechVoiceprintDiagClear,
                onTap: () => ref.read(voiceprintLogProvider.notifier).clear(),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 录一句（约 3 秒）→ 算声纹 → 和白名单比 → 显示结论。
  Future<void> _tryOne() async {
    final profiles = await ref.read(voiceprintProfilesProvider.future);
    if (!mounted || profiles.isEmpty) return;
    final cut = _cutoffs(ref.read(callSettingsProvider), profiles.length);
    final l10n = context.l10n;

    setState(() {
      _note = null;
      _last = null;
      _recording = true;
    });

    final ok = await _channel.startRecording();
    if (!ok) {
      if (mounted) {
        setState(() {
          _recording = false;
          _note = l10n.speechVoiceprintUnsupported;
        });
      }
      return;
    }
    // 三秒够说一句短话；不够也有 2 秒保底。
    await Future<void>.delayed(const Duration(milliseconds: 3000));
    final result = await _channel.stopRecording();
    if (!mounted) return;
    setState(() {
      _recording = false;
      _busy = true;
    });

    try {
      if (result == null || result.milliseconds < 800) {
        if (mounted) setState(() => _note = l10n.speechVoiceprintDiagTryShort);
        return;
      }
      // 整段（约 3 秒）
      final v = await _channel.embed(result.samples);
      if (v == null || v.isEmpty) {
        if (mounted) setState(() => _note = l10n.speechVoiceprintDiagTryFail);
        return;
      }
      // 同一段音频只取最后 600ms——**通话里用的就是这个长度**。
      // 两个数差多少，就知道"窗口太短"贡献了多少损失。
      final tail = result.samples.length > 9600
          ? result.samples.sublist(result.samples.length - 9600)
          : result.samples;
      final short = await _channel.embed(tail);
      // 和所有模板比，取最像的那个——和通话里判定的算法一致。
      final closest = VoiceprintStore.closest(profiles, v);
      final score = closest.score;
      final kind = score >= cut.accept
          ? VoiceprintKind.you
          : (score <= cut.reject ? VoiceprintKind.other : VoiceprintKind.unknown);
      final shortScore = short == null || short.isEmpty
          ? null
          : VoiceprintStore.closest(profiles, short).score;
      if (mounted) {
        setState(
          () => _last = (
            score: score,
            kind: kind,
            short: shortScore,
            // 建议门槛：拿**短窗口**那个分数当依据，因为它才是通话里真正
            // 参与判定的长度。比它低 0.08，留一句之差（换个句子分数会抖）。
            //
            // 两个都要在：短窗口没有就算了，只有整段的数不能代表通话。
            suggest: shortScore == null ? null : (shortScore - _suggestMargin).clamp(0.05, 0.95),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 和 Kotlin 的 Thresholds.accept 同一条曲线。
  static ({double accept, double reject}) _cutoffs(CallSettings settings, int count) {
    // 直接问那份唯一的实现，别在这里重抄一遍曲线——之前抄漏了 RELAXED 档，
    // 加档位时编译器会发现，但两处数字早晚会走岔。
    final accept = VoiceprintChannel.acceptFor(settings.voiceprintLevel.wire, count);
    return (accept: accept, reject: accept - VoiceprintChannel.band);
  }



  static String _name(VoiceprintKind kind, L10n l10n) => switch (kind) {
    VoiceprintKind.you => l10n.speechVoiceprintDiagYou,
    VoiceprintKind.other => l10n.speechVoiceprintDiagOther,
    VoiceprintKind.unknown => l10n.speechVoiceprintDiagUnknown,
  };

  static String _time(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';
}
