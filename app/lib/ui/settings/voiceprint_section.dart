import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../nativemedia/speaker_gate_bridge.dart' show VoiceprintChannel;
import '../../speech/speech_audio.dart';
import '../../speech/speech_settings.dart';
import '../../speech/voiceprint_store.dart';
import 'choice_list_page.dart';
import 'graded_slider_tile.dart';
import 'settings_widgets.dart';
import 'voiceprint_entry_page.dart';

/// 声纹：总闸、模型参数、录入入口。
///
/// 组的顺序按**配置依赖**排：开关在前，它控制的下游在后。总闸没开时
/// 模型和录入摆在那也没有消费者。
///
/// 为什么把这几项从散落的页面收进一张卡：它们本来分散在实景测试页、
/// 声纹列表页、语音链路诊断页三处，同一个设置改完不知道有没有生效。
class VoiceprintSection extends ConsumerWidget {
  const VoiceprintSection({super.key});

  /// 滑条该显示在哪个位置：用户拖过的绝对值优先，否则按档位基线。
  static double _acceptOf(CallSettings call) =>
      call.voiceprintAccept ??
      switch (call.voiceprintLevel) {
        VoiceprintLevel.loose => 0.40,
        VoiceprintLevel.normal => 0.50,
        VoiceprintLevel.strict => 0.60,
        VoiceprintLevel.veryStrict => 0.70,
      };

  Future<void> _pickEnrollSource(BuildContext context, WidgetRef ref) async {
    final current = ref.read(enrollSourceProvider);
    final picked = await showChoicePage<VoiceProfileSource>(
      context,
      title: '录入音源',
      selected: current,
      footer: '录模板用的音源要和通话判定用的一致，否则同一个人的两段音频落在'
          '不同幅度区间，分数会明显偏低。选「跟通话」就不用操心这件事。',
      options: const [
        ChoiceOption(VoiceProfileSource.call, '跟通话（推荐）', subtitle: '和通话判定用同一路声音，分数最准'),
        ChoiceOption(VoiceProfileSource.wake, '语音识别', subtitle: '电平通常更高，但和通话判定不同源，分数可能偏低'),
        ChoiceOption(VoiceProfileSource.raw, '原始麦克风', subtitle: '不经任何处理，电平最高。用于对照排查'),
        ChoiceOption(VoiceProfileSource.unprocessed, '未处理', subtitle: '要求系统不做音频处理，用于排查机器自带的音效'),
      ],
    );
    if (picked == null || !context.mounted) return;
    ref.read(enrollSourceProvider.notifier).state = picked;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callSettingsProvider);
    final on = call.voiceprint;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 总闸单独一张卡：它在配置依赖上高于下面所有项，摆在一起容易被
        // 当成「同一级的一个开关」。
        SettingsSection(
          title: '声纹',
          footer: const Text('开后只认本人的声音。关掉的话谁说话都能打断'),
          children: [
            SettingsSwitchTile(
              key: const ValueKey('vp-enabled'),
              title: '声纹识别',
              subtitle: '通话时只认本人的声音',
              value: call.voiceprint,
              onChanged: (v) => unawaited(
                ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(voiceprint: v)),
              ),
            ),
            SettingsSwitchTile(
              key: const ValueKey('vp-wake'),
              title: '唤醒声纹',
              subtitle: '唤醒也走声纹判定',
              value: call.voiceprintWake,
              enabled: on,
              onChanged: on
                  ? (v) => unawaited(
                        ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(voiceprintWake: v)),
                      )
                  : null,
            ),
          ],
        ),
        SettingsSection(
          title: '声纹模型',
          children: [
            GradedSliderTile(
              key: const ValueKey('vp-accept'),
              title: '判定门槛',
              subtitle: '声音多像你才算你。调高更严，旁人不容易被认成你，但你自己也可能被挡住',
              // 从设置里读。之前放 provider，结果是改任何一个别的选项都会把
              // 它冲回档位基线（provider 被重建），用户看到"滑条自己跳回 0.4"。
              // 存在 CallSettings 里就跟着设置走，不会被别人冲掉。
              value: _acceptOf(call),
              min: 0.20,
              max: 0.95,
              enabled: on,
              grades: const [
                (0.40, '宽松'),
                (0.50, '标准'),
                (0.60, '严格'),
                (0.70, '最严'),
              ],
              onCommit: (v) {
                unawaited(ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(voiceprintAccept: v)));
                unawaited(VoiceprintChannel().setAccept(v));
              },
            ),
            SettingsSegmentTile<VoiceprintMic>(
              key: const ValueKey('vp-silence'),
              title: '静默检测',
              badge: 'VAD',
              subtitle: '多大声算「有人在说」。机器收得小声就往下调，'
                  '否则整段人声会被当成静音丢掉',
              segments: const [
                PillSegment(VoiceprintMic.normal, '正常'),
                PillSegment(VoiceprintMic.quiet, '偏小'),
                PillSegment(VoiceprintMic.faint, '极小'),
              ],
              selected: call.voiceprintMic,
              enabled: on,
              onChanged: on
                  ? (v) => unawaited(
                        ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(voiceprintMic: v)),
                      )
                  : null,
            ),
            SettingsSegmentTile<CallBargeSensitivity>(
              key: const ValueKey('vp-barge-sensitivity'),
              title: '插话灵敏度',
              subtitle: 'AI 说话时，多高才放进来做声纹判定。'
                  '调高可避免被自己的回声打断，代价是插话要说得更清楚',
              segments: const [
                PillSegment(CallBargeSensitivity.sensitive, '灵敏'),
                PillSegment(CallBargeSensitivity.normal, '标准'),
                PillSegment(CallBargeSensitivity.guarded, '谨慎'),
                PillSegment(CallBargeSensitivity.resistant, '抗误触'),
              ],
              selected: call.sensitivity,
              enabled: on,
              onChanged: on
                  ? (v) => unawaited(
                        ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(sensitivity: v)),
                      )
                  : null,
            ),
            SettingsSwitchTile(
              key: const ValueKey('vp-others'),
              title: '他人打断',
              subtitle: '旁人说话也算打断。关掉只认本人',
              value: call.voiceprintOthers,
              enabled: on,
              onChanged: on
                  ? (v) => unawaited(
                        ref.read(callSettingsProvider.notifier).edit((s) => s.copyWith(voiceprintOthers: v)),
                      )
                  : null,
            ),
          ],
        ),
        SettingsSection(
          title: '声纹录入',
          children: [
            SettingsTile(
              key: const ValueKey('vp-entry'),
              title: '我的声音',
              subtitle: '录入与删除、链路自测、实景插话测试',
              enabled: on,
              onTap: on
                  ? () => unawaited(Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const VoiceprintEntryPage()),
                      ))
                  : null,
            ),
            SettingsTile(
              key: const ValueKey('vp-enroll-source'),
              title: '录入音源',
              subtitle: '录模板用哪一路，需和通话判定一致',
              enabled: on,
              value: Text(ref.watch(enrollSourceProvider).label),
              onTap: on ? () => unawaited(_pickEnrollSource(context, ref)) : null,
            ),
          ],
        ),
      ],
    );
  }

}

/// 录入音源。存在 `VoiceProfile` 之外的地方，用一层内存态先兜住——
/// 正式存储等录入流程改造时再接（见 voice-settings-audit §10）。
final enrollSourceProvider = StateProvider<VoiceProfileSource>((ref) => VoiceProfileSource.call);
