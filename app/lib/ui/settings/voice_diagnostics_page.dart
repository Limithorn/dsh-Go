import 'package:flutter/material.dart';

import 'aec_diagnostics_page.dart';
import 'speech_diagnostics_page.dart';
import 'voiceprint_diagnostics_page.dart';

/// 语音诊断的总入口：原来三个独立页，现在一个页三档。
///
/// 合并的理由是这三页问的是同一个问题——「现在为什么用不了」——只是从
/// 不同层面看：
/// - **链路**：每一道闸当前的线画在哪（值对不对）
/// - **声纹**：录一句立刻看被判成什么（分数够不够）
/// - **回声**：AEC 开没开、断在哪一层（是不是自己在打断自己）
///
/// 分开的时候，查一个问题要先想「该进哪页」，进去发现不对再退出来进另一页。
/// 合起来之后切一下就换层，不用来回跳。
///
/// 每页各自保留原来的实现（都还是独立 widget），这里只负责装 Tab——
/// 免得把三份状态逻辑揉在一起，改一处影响三处。
class VoiceDiagnosticsPage extends StatelessWidget {
  const VoiceDiagnosticsPage({super.key, this.initialTab = 0});

  /// 从别处直接跳到某一档（0 链路 / 1 声纹 / 2 回声）。
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('语音诊断'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '链路'),
              Tab(text: '声纹'),
              Tab(text: '回声'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            SpeechDiagnosticsPage(embedded: true),
            VoiceprintDiagnosticsPage(embedded: true),
            AecDiagnosticsPage(embedded: true),
          ],
        ),
      ),
    );
  }
}
