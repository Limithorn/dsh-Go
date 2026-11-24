# 语音功能架构迁移计划（fix → 上游 main）

> 状态：**待确认**，尚未执行任何代码改动。
> 生成日期：2026-11-25
> 基准：`main` = `origin/main` = `8e31a2e26`（纯净锚点）；`fix/mic-source-unify` = `7861df20b`（78 个本地提交，落后上游 819）。
> 分叉点（merge-base）：`51f25408e`。
> 保底：`archive/fix-before-rebase-20261125` 等 10 个归档 tag 均已就位。
> **路径基准**：文中 `android/...`、`lib/...`、`test/...` 均相对 `app/` 目录；`docs/...` 相对仓库根目录。

---

## 一、为什么要迁移

本地语音功能（AEC / 声纹 / 唤醒词 / 收起卡片 / PiP）写在上游**旧架构**上。上游 819 个提交里做了 4 项重大重构，导致：

- `git rebase`：第 1/78 个提交就冲突（真实内容冲突，CRLF 不是主因），后续 77 个逐个重放 —— 历史上就是这么丢过改动的。
- `git merge`：14 个文件冲突，其中 9 个可三方合并自动解决，**6 个是两套架构正面碰撞**。

结论：这不是普通冲突解决，而是**把语音功能移植到新架构**。本文档就是这个移植的施工方案。

---

## 二、新旧架构对照

| 维度 | 旧架构（fix 所在） | 新架构（main） | 对迁移的影响 |
|---|---|---|---|
| 引擎管理 | `MainActivity` 内联 new 引擎 + 30+ 插件注册 | `DshFlutterEngine.kt` 单例 + `FlutterEngineCache`，Activity/Service 各持租约 | 插件注册点从 Activity 搬到单例；**唤醒词 `WakePlugin` 会失去注册点** |
| 通话 UI | `VoiceCallHost` 单例托管 controller + `CallCardLayer` 收起卡片 + `CallPipView` | 页面自造 `VoiceCallController` + `CallBackdrop`（sea/image/companion）+ `verbatimInput` 逐字模式 | "谁持有 controller"正面冲突；逐字回调在 host 架构下无落点 |
| 后台保活 | PiP + `CallNotification` + `WakeWordService`（麦克风前台服务） | `CompanionAlwaysOnService` 前台服务 + `CompanionResidency` + 通知 | **两套保活机制**；PiP/通知相关代码在新架构里被整段删除 |
| 伙伴舞台 | `companion_stage_commands.dart` 抽出 controller | `CompanionStage` 内联 controller，新增 cover 模式 + viewKey 记忆 | 本地抽取与语音无关，可直接取上游 |
| 语音识别 | `SpeechPlugin`（`dsh/speech`，本地扩到 30+ 方法） | `runtime/SpeechGuest.kt` SenseVoice guest patch + companion 插件 | `SpeechPlugin` 上游仍在，但方法少；本地扩写要保住 |

---

## 三、迁移策略

**基底**：以上游 `main` 的代码为骨架，把本地语音功能按新挂点重新接线。
**操作形式**：在 `fix/mic-source-unify` 分支上 merge `main`（不新开分支、不碰 `main`），逐个解决冲突。
**顺序**：先机械搬移（挂点明确） → 再语义融合（同一区域两套逻辑） → 最后补功能缺口 → 编译与真机验证。

### 三阶段执行顺序

1. **阶段 A — 自动可合并的 9 个文件**：用 `git merge-file` 三方合并（merge-base / ours / theirs 全转 LF），已验证 `CallCapture.kt` 零冲突。合并后逐个检查语义（尤其 `SpeechPlugin.kt`）。
2. **阶段 B — 6 个架构级文件**：按第四节方案手工融合。
3. **阶段 C — 挂点补建与功能缺口**：把没有挂点的功能搬到新位置，修掉已知的功能 bug（见第六节）。

---

## 四、逐文件迁移方案（14 个冲突文件）

### 可直接取上游（1 个）

| 文件 | 操作 |
|---|---|
| `lib/ui/companion/companion_stage.dart` | **取 main 版本**。上游新增 cover 模式、viewKey 记忆是实质功能；本地的"抽出 controller 到 `companion_stage_commands.dart`"只是位置重构，**与语音功能无关**（已核实 `VoiceCallHost` 不引用它）。取上游后删除 `lib/companion/companion_stage_commands.dart`（唯一 import 方就是本文件）。`voice_call_page` 的 `_stage.command()` 调用方式不变。 |

### 以上游为底、叠加本地（2 个）

**`android/.../MainActivity.kt`**
- 取上游的 `provideFlutterEngine()` → `DshFlutterEngine.getOrCreate(context)`（引擎管理整体委托）。
- **必须补**：把 `WakePlugin()` 注册从旧内联块迁到 `DshFlutterEngine.getOrCreate()` 的 `plugins.add` 列表 —— 这是唤醒词在新架构里的唯一注册点。
- 把本地的语音 MethodChannel 分支（PiP / 锁屏 / 音量键 / 通知）搬进上游 `configureFlutterEngine()` 的 `when`，与上游新增的 `companionAssistant*` 分支并存（不同 case，不冲突）。
- 合并 `onResume`/`onStop`/`cleanUpFlutterEngine`：上游的 `refreshBinding`、`finishAssistantYield` 与本地的 `callScreenLocked`、PiP 重对齐写进同一函数体。
- `applyRefreshRate()` 取上游。
- ⚠️ PiP / `CallNotification` 是否保留见第六节决策点 D3。

**`lib/app.dart`**
- 保留上游全部改动：常驻伙伴 `watch(companionAlwaysOnOwnerProvider)`、`companionPhoneSessionsBridgeProvider`、`petOverlayBridgeProvider`；`didChangeLocales` 的 `notifyChannelProvider.status()`；locale 切换 invalidate `runActivityProvider`；`performanceDefaultsProvider` 改 `.select`。
- 叠加本地 3 处：3 行 import、`initState()` 的 `warmLocalTts()`、`MaterialApp` 的 `navigatorKey: rootNavigatorKey`。三者与上游改动位置不重叠，直接叠加。

### 以本地为底、叠加上游（2 个）

**`lib/speech/call/voice_call.dart`**
- 叠加上游：`verbatimInput` 构造字段（`bool Function()?`）；`send()` 加 `verbatimInput?.call() == true ? _heard : message`——**注意本地有 `_pendingSend`，`_retrySend()` 里也要按同一规则处理**；`CallReply.text` 改为"最新可见回复"语义；`_onReply()` 换成 `text != _reply` / `startsWith(_reply)` 判断（顺带删本地残留的 `_spoken`）；`SpeechOutStarted` 加 `duck`/`cutIn`（与本地 `_voiceWatch?.cancel()` 共存）；`start()` 加 `disposed`/`ended` 保护。
- 保留本地全部：`CallChoices` 4 个新字段（sensitivity / voiceprint / voiceprintOthers / callMicSource）；删除 `requiresSpeakerAck` 握手；`SpeechJudge` 三态声纹门控与 `_pendingSend` 重试；`_watchVoice()` 兜底。
- 验证：`flutter test test/speech/voice_call_test.dart`（上游 5 个新用例 + 本地 6 个声纹用例同时通过）。

**`lib/ui/speech/voice_call_page.dart`（最难）**
- 保留本地 host 架构作为骨架：`openChatCall` → `VoiceCallHost`、`controller`/`onCollapse` 参数、`pushVoiceCallPage`/`pushScriptedTestCall`、`CollapsedCallCard`/`CallPipView`、`_collapse()`、`PopScope`。
- 叠加上游：补回 `openVoiceCall()`（用本地 `pushVoiceCallPage` 实现，`backdrop` 作为 `widget.backdrop` 传入，建议也走 `host.openCall()`）；`VoiceCallPage` 加 `backdrop` 字段，build 用 `widget.backdrop ?? settings.backdrop`；叠加 `_shows()` 增量 setState（**必须加入本地的 `_collapsed` / `pictureInPictureMode.value`，否则收起和小窗后不刷新**）与 `_imageChecked` 缓存；补 `CompanionCallConversation` 的 sessionId/watch 分支。
- ⚠️ **重新设计**：上游 `verbatimInput` 在 `initState` 构造 controller 时传，但本地 controller 由 `VoiceCallHost` 构造 —— 必须把回调下沉到 `VoiceCallHost` 构造处，否则逐字模式失效（决策点 D1）。
- 验证：`voice_call_page_test.dart` + `collapsed_call_flow_test.dart` + `collapsed_card_hit_test.dart` + `call_card_controls_test.dart` + 上游 companion 房间通话用例；真机跑收起→展开→PiP→锁屏叫醒全链路。

### 测试文件（1 个，可合并型）

**`test/speech/voice_call_test.dart`**
- 参数取并集：`makeVoice`/`verbatim`（上游）+ `voiceprint`/`voiceprintOthers`（本地）；`choices` 保留本地 4 字段并补 `verbatimInput: () => verbatim`；两版新增用例全保留。
- 前提：`test/speech/speech_fakes.dart`（自动合并的 9 个之一）合并后必须保留 `FakeOut.duck`/`canDuck` 与 `SpeechJudge`，否则上游用例编译不过。

### 自动合并的 9 个文件（需语义复核）

`AndroidManifest.xml`、`app/lib/app.dart`（见上）、`AndroidManifest`、`CallCapture.kt`、`PcmStream.kt`、`app_en.arb`、`app_zh.arb`、`app/test/speech/speech_fakes.dart`、`page_frame.dart`、`companion_voice_page.dart`、`voice_call.dart` 测试等。
其中重点复核：
- `CallCapture.kt` / `PcmStream.kt`：确认软件 AEC 在增益/电平之前、播放侧参考喂入的时序没被上游改动打乱。
- `SpeechPlugin.kt`（**不在 14 个冲突文件里，但必须单独处理**）：上游只有 11 个 `dsh/speech` 方法，本地扩到 30+（AEC / 声纹 / MicSource / probe / screenTest）。合并后要确认本地方法全部保留，且 `onAttachedToEngine()` 里的 `SoftwareAec.setEnabled()` 与上游注册机制不冲突。

---

## 五、本地功能 → 新架构落点映射

| 本地功能 | 新架构落点 | 机械搬移 / 重新设计 |
|---|---|---|
| 唤醒词 KWS（`WakePlugin` + `WakeWordService`） | `DshFlutterEngine.getOrCreate()` 注册；Manifest 前台服务 | 机械搬移 |
| AEC（AecSupport / AecReference / SoftwareAec / VoiceProbe） | `SpeechPlugin` + `CallCapture` + `PcmStream`，`dsh/speech` 方法 | 机械搬移 + 修参考点缺口（D4） |
| SpeakerGate 声纹门控 | `SpeechPlugin.createGate()` → `Voiceprint.gateFor()`；`TurnGate.bargeOffset` 扩展 | 机械搬移（上游 `TurnGate` 需补 `bargeOffset`） |
| MicSource 统一 / 固定增益 | `CallCapture` / `PcmStream` + `dsh/speech` 方法 | 机械搬移 |
| 声纹录入 / 诊断页 / 存储 | Dart 侧基本独立，`dsh/speech` 的 13 个 `voiceprint*` 方法 | 机械搬移（配置推送仍走 host） |
| Edge / Kokoro TTS | `CompanionVoiceSource` 枚举 + `fetchCompanionVoice()`；`app.dart` 预热 | 机械搬移，成本最低 |
| VoiceCallHost / 收起卡片 | `voice_call_page.dart` + `root_gate.dart` + `voice_call_host.dart`（非冲突） | 保留本地架构，补 verbatim 落点（D1） |
| PiP / CallNotification / 锁屏 | `MainActivity` + `voice_call_page.dart` + `state/picture_in_picture.dart`（非冲突） | 保留本地，但要与常驻服务共存（D3） |

---

## 六、需要你拍板的决策点

| # | 决策 | 选项 A | 选项 B |
|---|---|---|---|
| **D1** | `verbatimInput` 逐字模式在 host 架构下的落点 | 下沉到 `VoiceCallHost` 构造 controller 处（保留上游功能） | 放弃逐字模式（本地 host 架构不需要） |
| **D2** | `companion_stage.dart` 的 controller 抽取 | 取上游、删 `companion_stage_commands.dart`（推荐，与语音无关） | 保留抽取，把 cover/viewKey 手工补进抽出版（额外工作） |
| **D3** | PiP / `CallNotification` 保活机制 | 移植回新 `MainActivity`，与 `CompanionAlwaysOnService` 并存（保留本地体验，两套机制） | 放弃 PiP/本地通知，改走上游前台服务 + 通知（代码更干净，但通话中切后台行为变化） |
| **D4** | 软件 AEC 的参考信号 | 迁移时顺手修：在 `dsh/companion_voice` / `ClipPlayer` 播放路径重新挂参考（需额外代码） | 先原样搬移，保留已知缺陷（当前有效帧为 0，见 `docs/testing/voice-aec-field-probe.md`） |

> D3 是最重要的一条：它决定"通话中切到后台"的产品行为，不是纯技术问题。
> D4 是已知的功能 bug —— 软件 AEC 挂在 `PcmStream.write()`，但 AI 语音实际走系统 TTS，不经过这条路径，所以削减帧为 0。

---

## 七、执行与验证清单

**执行前置**：工作区有 15 个已跟踪修改 + 5 组未跟踪文件（含你最近的 SpeakerGate / voice_settings_page 改动）→ 需 `git stash -u` → merge + 解冲突 → commit → `git stash pop`（上一轮已验证 stash/pop 循环可行，但**成功 merge 后 pop 是否会与已改动文件冲突尚未验证**，届时重点检查）。

**编译与静态检查**
- `cd app && flutter pub get && flutter analyze`
- `./tool/build_apk.sh`（含 AOT 预跑）

**测试**
- `flutter test test/speech/voice_call_test.dart`（11 个新增用例 + 原有回归）
- `collapsed_call_flow_test.dart`、`collapsed_card_hit_test.dart`、`call_card_controls_test.dart`
- `companion_stage_guard_test.dart`、`companion_stage_query_test.dart`、`companion_stage_visibility_test.dart`
- Kotlin：`SoftwareAecTest.kt`、`KaldiFbankTest.kt`、`SpeechGateTest.kt`

**真机场景**（语音相关模拟器测不出来）
1. 唤醒词能否唤出 → 验证 `WakePlugin` 在 `DshFlutterEngine` 注册成功
2. 声纹白名单：只认录入的人，其他人说话不打断
3. 通话中按 home 进 PiP、锁屏叫醒、贴耳熄屏、挂断后通知撤销（若 D3=A）
4. 播放 AI 语音时不自打断 → 验证 SpeakerGate `OTHER_ECHO_FLOOR` 与软件 AEC 参考点
5. 伙伴房间 fullMode 下逐字模式生效（若 D1=A）
6. 离线 TTS 首句延迟、锁屏状态下唤醒词把通话页推到前台
7. 伙伴房间入场、缩放/位置记忆、工坊封面（上游新功能回归）

---

## 八、交付形态

- 迁移在 `fix/mic-source-unify` 分支上完成，不新建分支、不 merge 到 `main`。
- 建议拆成多个提交：① 自动合并的基础同步 ② MainActivity/引擎挂点 ③ voice_call 语义融合 ④ voice_call_page host 融合 ⑤ 功能缺口修复（D1/D3/D4）。
- 任一阶段失败可回退到 `archive/fix-before-rebase-20261125`。
