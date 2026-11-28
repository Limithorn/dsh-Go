import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../companion/companion_voice.dart';
import '../../speech/voiceprint_store.dart';
import '../shell/page_frame.dart';
import '../settings/settings_widgets.dart';
import 'screen_test_page.dart';
import 'voice_diagnostics_page.dart';
import 'voiceprint_enroll_page.dart';

/// 已录入的声音：最多 5 条，能改备注、能删、能再加一个。
///
/// 为什么不是设置页里的一小块：录一个人要三步、每步 6 秒，而且删掉是不可逆的
/// （声纹删了就得重录）。这些值得一整页，而不是塞在开关下面。
class VoiceprintListPage extends ConsumerWidget {
  const VoiceprintListPage({super.key});

  /// 回放录入时存下的那段音频。
  ///
  /// 复用 CompanionVoice 的播放通道：它已经处理了音频焦点、被打断、
  /// 回调时序这些事，没必要再养一个播放器。
  static Future<void> _play(String path) async {
    await CompanionVoice().play('voiceprint-clip', path);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final async = ref.watch(voiceprintProfilesProvider);
    final profiles = async.value ?? const <VoiceProfile>[];
    final full = profiles.length >= VoiceprintStore.maxProfiles;

    return AppPage.list(
      title: l10n.speechVoiceprintListTitle,
      children: [
        if (async.isLoading && profiles.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          SettingsSection(
            children: [
              for (var i = 0; i < profiles.length; i++)
                SettingsTile(
                  key: ValueKey('voiceprint-${profiles[i].id}'),
                  title: _name(context, profiles[i], i),
                  // 音源要显出来：同一个人可能有两份（通话一份、唤醒一份），
                  // 只看「#1 #2」分不清哪份是哪种场景录的。
                  subtitle:
                      '${profiles[i].source.label} · ${l10n.speechVoiceprintRecordedAt(_shortDate(profiles[i].createdAt))}'
                      '${profiles[i].clipPath.isEmpty ? '' : ' · 可回放'}',
                  // 有录音就给个独立的回放入口：点整行是进详情，容易点错。
                  // 旧版本录的没有音频，这时候不给按钮。
                  trailing: profiles[i].clipPath.isEmpty
                      ? null
                      : IconButton(
                          key: ValueKey('voiceprint-play-${profiles[i].id}'),
                          icon: const Icon(Icons.play_circle_outline, size: 20),
                          tooltip: '回放当时的录音',
                          onPressed: () => unawaited(_play(profiles[i].clipPath)),
                          visualDensity: VisualDensity.compact,
                        ),
                  onTap: () => unawaited(_open(context, ref, profiles[i])),
                ),
            ],
          ),
          SettingsSection(
            children: [
              SettingsTile(
                key: const ValueKey('voiceprint-add'),
                title: l10n.speechVoiceprintAdd,
                subtitle: full ? l10n.speechVoiceprintFullHint : null,
                value: full ? Text(l10n.speechVoiceprintFull) : null,
                // 到 5 位就置灰：任务要求"添加第 6 位"必须失败，界面上先不给入口。
                onTap: full
                    ? null
                    : () => unawaited(Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => const VoiceprintEnrollPage()),
                        )),
              ),
            ],
          ),
          // 诊断入口放在最下面：它是给调阈值用的，不是日常操作。
          SettingsSection(
            children: [
              // 三页合成一页三档：链路 / 声纹 / 回声。
              //
              // 原来三个独立入口，查一个问题要先想「该进哪页」，进去发现不对
              // 再退出来进另一页。合成 Tab 之后切一下就换层。
              SettingsTile(
                key: const ValueKey('voice-diagnostics'),
                title: '语音诊断',
                subtitle: '链路每道闸的值、录一句看判成什么、AEC 断在哪一层',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const VoiceDiagnosticsPage()),
                )),
              ),
              SettingsTile(
                key: const ValueKey('speech-screen-test'),
                title: '实景测试',
                subtitle: '我说话的时候你插话，看能不能打断；录音可回听',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ScreenTestPage()),
                )),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static String _name(BuildContext context, VoiceProfile p, int index) =>
      p.label.isNotEmpty ? p.label : '#${index + 1}';

  static String _shortDate(DateTime at) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return at.year == now.year
        ? '${two(at.month)}-${two(at.day)}'
        : '${at.year}-${two(at.month)}-${two(at.day)}';
  }

  Future<void> _open(BuildContext context, WidgetRef ref, VoiceProfile profile) async {
    final l10n = context.l10n;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SettingsTile(
              title: l10n.speechVoiceprintRename,
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(_rename(context, ref, profile));
              },
            ),
            SettingsTile(
              title: l10n.speechVoiceprintDelete,
              danger: true,
              onTap: () {
                Navigator.of(sheet).pop();
                unawaited(_delete(context, ref, profile));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, VoiceProfile profile) async {
    final l10n = context.l10n;
    final controller = TextEditingController(text: profile.label);
    final next = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.speechVoiceprintRename),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.speechVoiceprintProfiles),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(l10n.speechVoiceprintCancel)),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text.trim()),
            child: Text(l10n.speechVoiceprintAdd),
          ),
        ],
      ),
    );
    controller.dispose();
    if (next == null) return;
    await ref.read(voiceprintProfilesProvider.notifier).rename(profile.id, next);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, VoiceProfile profile) async {
    final l10n = context.l10n;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.speechVoiceprintDelete),
        content: Text(l10n.speechVoiceprintDeleteConfirm),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(l10n.speechVoiceprintCancel)),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(l10n.speechVoiceprintDelete),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ref.read(voiceprintProfilesProvider.notifier).remove(profile.id);
  }
}
