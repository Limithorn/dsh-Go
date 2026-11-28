import 'dart:async';

import 'package:flutter/material.dart';

import 'screen_test_page.dart';
import 'settings_widgets.dart';
import 'speech_self_test_page.dart';
import 'voiceprint_list_page.dart';

/// 声纹的子页：录声音、测效果。
///
/// 之前这里有五行，其中「声音管理」和「录一份新的」其实是一个入口的两种
/// 叫法（进去都是模板列表，列表里有新建），「语音诊断」和「语音自测」也
/// 有大量重叠（都在查链路各道闸）。收成两组：
///
/// - **录入**：只管模板本身（录、试听、删）
/// - **测试**：只管验证效果
///
/// 测试里只留两个入口。原来四个（诊断、自测、实景、通话页测试）里，
/// 「自测」和「诊断」查的是同一件事的两面——自测看哪一环没跑起来，
/// 诊断看各道闸的数值——留**自测**因为它是新人该先点的那个；实景那三行
/// （实景测试、通话页测试、直接说话）其实就是同一个页面里的按钮，
/// 收成一行。
class VoiceprintEntryPage extends StatelessWidget {
  const VoiceprintEntryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的声音')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SettingsSection(
            title: '录入',
            footer: const Text('录得越接近真实通话，判定越准。换过手机或换过麦克风就要重录'),
            children: [
              SettingsTile(
                key: const ValueKey('vp-entry-list'),
                title: '我的声纹',
                subtitle: '看已录的几份、试听、删掉重录',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const VoiceprintListPage()),
                )),
              ),
            ],
          ),
          SettingsSection(
            title: '测试',
            footer: const Text('先跑自测确认链路通，再用实景测试验真实插话。实景要开麦克风，别在嘈杂的地方做'),
            children: [
              SettingsTile(
                key: const ValueKey('vp-entry-selftest'),
                title: '链路自测',
                subtitle: '逐项检查：麦克风、识别、声纹、播放哪一环没通',
                onTap: () => unawaited(Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SpeechSelfTestPage()),
                )),
              ),
              SettingsTile(
                key: const ValueKey('vp-entry-screen'),
                title: '实景插话测试',
                subtitle: '让我一直说话，你插话，看能不能打断；录音可回听',
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
