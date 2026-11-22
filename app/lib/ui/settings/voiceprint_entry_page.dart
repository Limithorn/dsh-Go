import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import 'settings_widgets.dart';
import 'screen_test_page.dart';
import 'speech_self_test_page.dart';
import 'voiceprint_enroll_page.dart';
import 'voiceprint_list_page.dart';
import 'voice_diagnostics_page.dart';

/// 声纹的子页：录入、测试、诊断、实景测试四个入口。
///
/// 为什么收在一层里而不是直接平铺在语音页：这四项都是「动手做的事」，
/// 和上面那些「调参数」的行不是一类。平铺会让语音页变成九行，找参数时
/// 要先跳过它们。收进子页后，语音页只留参数，动作都在这里。
class VoiceprintEntryPage extends ConsumerWidget {
  const VoiceprintEntryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: const Text('声音管理与测试')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SettingsSection(
            title: '录入',
            children: [
              SettingsTile(
                key: const ValueKey('vp-entry-list'),
                title: l10n.speechVoiceprintProfiles,
                subtitle: '已有几份、删改、重录',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const VoiceprintListPage()),
                )),
              ),
              SettingsTile(
                key: const ValueKey('vp-entry-enroll'),
                title: '录一份新的',
                subtitle: '按提示说三段话，录完当场看效果',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const VoiceprintEnrollPage()),
                )),
              ),
            ],
          ),
          SettingsSection(
            title: '测试',
            footer: const Text('先「语音自测」看链路通不通，再「实景测试」验实际插话'),
            children: [
              SettingsTile(
                key: const ValueKey('vp-entry-diag'),
                title: '语音诊断',
                subtitle: '链路每道闸的值、录一句看判成什么、回声消除断在哪层',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const VoiceDiagnosticsPage()),
                )),
              ),
              SettingsTile(
                key: const ValueKey('vp-entry-selftest'),
                title: '语音自测',
                subtitle: '不用打电话，逐项跑一遍看哪一环断了',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SpeechSelfTestPage()),
                )),
              ),
              SettingsTile(
                key: const ValueKey('vp-entry-screen'),
                title: '实景测试',
                subtitle: '我说话的时候你插话，看能不能打断；录音可回听',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ScreenTestPage()),
                )),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
