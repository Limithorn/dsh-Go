# dsh-Go 自研分支：模块化与上游同步规范（草案 v1）

> 2026-11-25。依据：`fix/mic-source-unify` 对 `main` 全量 diff（118 文件，+23934/−3857，
> 约 80 个本地提交）与该分支上的 7 篇交接/设计文档（voiceprint-handoff、wake-call-on-companion、
> voice-round-handoff、voice-settings-audit、voice-settings-page、architecture-migration-plan、
> voice-aec-field-probe）。本文件应 MIC-92 的梳理结论落于 `docs/design/`，是后续在自研分支上
> 逐功能点重构的执行依据；如与 `refactor-2026-11.md` 并行执行，两份方案的避让原则一致、互不覆盖。

---

## 0. 一句话总纲

**上游文件当依赖，不当底稿。** 每个功能点是一个模块：自有文件承载实现，上游文件里只留
最小、集中、可登记、可 grep 的挂点；每个模块默认可关、关闭时行为与上游一致、有自己的
测试与交接文档。上游更新时按登记表核对挂点、用 merge 吸收，不重放长历史。

---

## 1. 分区模型：把 fork 改动分成三区

| 区 | 定义 | rebase/merge 时的处理 |
|---|---|---|
| **A 自有区**（fork-owned） | fork 新增的文件：`speech/Voiceprint*.kt`、`wake/**`、`lib/speech/edge_tts.dart`、`state/wake_*.dart` 等 | 零冲突；只受上游 API 变更影响，编译器会告诉我们 |
| **B 挂点区**（seams） | 对上游文件的少量修改：插件注册行、`MainActivity` 的 `when` 分支、`app.dart` 的 import+预热、Manifest 的 service/permission | 人工核对，量小可控，必须全部登记 |
| **C 共享区**（upstream-shared） | 在上游文件的既有结构里扩写：`SpeechPlugin.kt` 加方法、`CallSettings` 加字段、`voice_settings_page.dart` 重排、`speech_fakes.dart` 扩替身 | 真正的冲突高危区；目标是**缩小 C、迁往 A** |

规范的全部规则都服务于一个方向：**A 越大越好，B 尽量小且集中，C 只减不增。**

---

## 2. 十条规则

### R1 加法优先（A 区优先）

新功能尽量写成新文件，而不是在上游文件里长出来。判断标准：这个文件删掉后，上游代码
是否原样可编译（除了少数 import/注册行）。

- 正例：`wake/` 整个包、`edge_tts.dart`、`voiceprint_store.dart`、`CallSurfaceState`。
- 反例：`SpeechPlugin.kt` 从 11 个方法长到 45 个（+985/−332），所有语音功能挤一条
  `dsh/speech` 通道——这是当前最大的单文件冲突面。
- 检查：`git diff --numstat main` 里上游文件的改动行数，一个模块在一个上游文件里的
  落点超过 ~50 行就必须给出"为什么不放新文件"的理由。

### R2 挂点集中并打标记

必须改上游文件时（B 区）：改动集中、每处带统一前缀注释，rebase 时不靠记忆靠 grep。

```kotlin
// fork(wake): 引擎管理迁移后 WakePlugin 的唯一注册点
engine.plugins.add(io.github.ccch1mneyyy.dsh_app.wake.WakePlugin())
```

- Kotlin 插件注册：`DshFlutterEngine` 里一行一个插件。
- `MainActivity` 的 MethodChannel：只加独立 `case`，绝不与上游 case 交织；
  生命周期方法（`onResume`/`onPause`）里的 fork 逻辑用注释块包起来。
- Manifest：service/permission 独立块 + 用途注释（现分支已是这样）。
- Dart：入口集中在 `app.dart`、`root_gate.dart`、设置页入口、l10n `parts/*.arb`。
- 检查：`git grep -n "fork(" main..HEAD` 应能列全 B 区；列不全即违规。

### R3 通道分家，协议只做增量

新功能开自己的 MethodChannel，不往上游通道加方法；必须扩上游协议时只加可选键、
不改旧键语义。

- 正例：`dsh/wake` 独立通道；`MicSource` 对 `screenTestWindow` 只增
  `source/sourceRequested` 键，旧取值仍认、旧 Dart 行为不变。
- 反例：AEC/声纹/probe/屏幕测试 30+ 个方法全进 `dsh/speech`。重构方向：
  `dsh/voiceprint`、`dsh/aec`、`dsh/probe` 各自成通道，`dsh/speech` 只留上游
  原有 11 个方法 + `callStart` 的增量参数。
- 兼容铁律：不重命名、不改签名、不改旧参数含义；上游已有的方法签名不许本地改。

### R4 可插拔：默认关、关=原样、测试钉住

每个模块一个总开关；关闭时行为与上游一致，且"关=原样"必须有测试或直通不变量保证。

- 正例：`SpeakerGate` 三条不变量第一条——不播放/功能关/没模板时**完全直通**，与没有
  这一层时逐帧一致；软件 AEC 开关关闭回系统 AEC 路径；`VoiceProbe` 默认零开销。
- 检查：每个模块的 handoff 文档必须有"关闭时行为"一节；新模块的 PR 必须带一个
  "开关关闭时输出与上游一致"的测试。

### R5 状态分家：fork provider 独立文件，少在上游类里加字段

- 正例：`wake_state.dart`、`call_surface_state.dart`、`picture_in_picture.dart` 都是
  fork 独立 state 文件，不碰上游 provider。
- 反例：`CallSettings` 在 `speech_settings.dart` 里加了 10 个字段——该文件从此成为
  每次 upstream sync 的必冲突点。新增设置字段时优先考虑：fork 自己的
  `Notifier` + 自己的存储键，或 extension getter，把上游类的结构改动压到最小；
  做不到就在登记表标红，人工核对。
- 高频流不进全局 notifier：电平/字幕属于画它的舞台（`call_surface_state.dart` 的
  "只有 surface 是全局的"），避免每 50ms 全局重建风暴。

### R6 UI 架构决定先钉测试再动工

对"页面/路由/手势"这类 merge 时最容易悄悄变行为的改动，先用 widget 测试钉死根因，
再改架构。

- 已钉的范例：`collapsed_card_hit_test.dart`（透明路由收起后底下必点不到，才引出
  VoiceCallHost 架构）、`call_card_controls_test.dart`（卡片拖动/静音/返回语义）、
  `call_surface_state_test.dart`。
- 原生算法（AEC、fbank、gate）用离线合成信号断言：`SoftwareAecTest`（100ms 人造回声，
  断言削减>10dB、对齐±5ms）、`KaldiFbankTest`、`SpeechGateTest`——不依赖真机、
  引擎或噪声环境。

### R7 共享测试文件最小侵入

上游的测试基建（`speech_fakes.dart`）是隐性协议：上游改它、我们扩它，必撞。
fork 的替身与扩展尽量放独立文件；必须动共享 fakes 时，只加不改（`FakeOut.duck`
这类新增字段与上游用例兼容时才可加），并在登记表登记。

### R8 上游同步：merge 吸收，不 rebase 重放；行尾先归一

- `main` 只做锚点（既有约定）：不做本地提交，只作上游参照。
- 跟上游一律 `git merge upstream/main` 进工作分支。历史实证：跨 400+ 提交 rebase 时
  每个提交都要重解冲突，丢失改动机会是 merge 的 51 倍，且真的丢过——三方合并脚本曾
  弄丢 `SystemAsrCard` 整类（65 行）、`AppPage.list` 转发、`FakeAudio.startCall`
  参数、右括号等，靠跑测试才暴露。
- 每次同步前：`git fetch` 后先跑受影响模块的测试基线；同步后逐模块跑、逐模块提交，
  回退粒度=模块。同步前后打 `archive/*` tag（沿用 `archive/fix-before-rebase-*` 模式）。
- **行尾统一**：`.gitattributes` 目前只保护补丁文件，`app/android/gradle.properties`
  在本分支已被写成 CRLF（上游是 LF）。CRLF 正是把 `voice_call_page.dart` 1900 行标成
  整块冲突的元凶。规范：仓库文本文件一律 LF，`.gitattributes` 补
  `*.dart text eol=lf`、`*.kt text eol=lf`、`*.properties text eol=lf`、`*.gradle text eol=lf`；
  已混入的 CRLF 一次性归一（单独提交，不与功能混）。

### R9 资产可追溯：模型=代码

每个模型/大资产带四件套：来源 URL、SHA-256、大小、LICENSE 文本；assets 声明在
pubspec 集中一块 + 注释。

- 正例：`3dspeaker-campplus-LICENSE.txt` + 28MB onnx；`local_tts.dart` 的
  pack 注释（URL/sha256/bytes）；wake 模型 4 件套 + `keywords.txt/tokens.txt`。
- 检查：新资产 PR 必须能回答"从哪来、多大、什么许可、怎么校验"。

### R10 文档三段式 + 勘误保留

每个模块配 `docs/design/<module>-handoff.md`，结构沿用 voiceprint-handoff 的范式：

1. **已确认**（带数据证据：日志行、实测 dB 表、唯一值统计）；
2. **已排除**（防止下一个人重走弯路）；
3. **未解决/决策点**（显式编号：D1、D2…，写清选项与代价）。

写错的结论用勘误框保留原文，不删除——勘误本身记录了"怎么把问题定量下来"。
另两条硬约束照仓库 AGENTS：真机验证清单进文档（CI 绿≠手机没问题）；
文案走 `parts/*.arb` 中英同步 + `l10n_merge.py`，不手改生成物。

---

## 3. 上游接触面登记表（fork-seams）

> 落地为 `docs/design/fork-seams.md`，每次 upstream sync 后核对更新。
> 表格是规范的核心工件：rebase/merge 时逐行核对，不靠记忆。

现状首版（按 2026-11-25 的 diff 整理，模块→上游文件挂点→冲突热度）：

| 模块 | 自有区（A） | 上游挂点（B） | 共享区热点（C，冲突热度） |
|---|---|---|---|
| 唤醒词 | `wake/WakePlugin.kt`、`WakeCapture.kt`、`WakeWordService.kt`、`lib/speech/wake_*.dart`、`state/wake_*.dart`、`assets/wake/*`、`values*/wake_strings.xml` | `DshFlutterEngine` 注册 1 行；Manifest service+permission；`app.dart` `navigatorKey`、import 3 行 | 无（好范例） |
| 声纹 | `nativemedia/CampplusEmbedder.kt`、`SpeakerGate.kt`、`Thresholds.kt`、`speech/Voiceprint*.kt`、`lib/speech/voiceprint_*.dart`、`sherpa_speaker_embedder.dart`、`nativemedia/speaker_gate_bridge.dart`、enroll/list/diagnostics 页 | `SpeechPlugin.createGate()` 挂接；`TurnGate.bargeOffset` 扩展 | `SpeechPlugin.kt` 45 方法（**高**）；`CallSettings` 10 字段（**高**）；`speech_fakes.dart`（中） |
| AEC/音源 | `speech/AecSupport.kt`、`AecReference.kt`、`SoftwareAec.kt`、`EchoTone.kt`、`MicSource.kt`、`VoiceProbe.kt`、aec_diagnostics 页 | `PcmStream.write()` 喂参考；`CallCapture` 过 AEC | `SpeechPlugin.kt`（**高**）；`CallCapture.kt`/`PcmStream.kt`（中，时序敏感） |
| TTS 双引擎 | `lib/speech/local_tts.dart`、`edge_tts.dart` | `companion_voice_source.dart` 枚举 + fetch 分支；`app.dart` 预热 | `companion_voice_source.dart`（低） |
| 通话形态 | `state/voice_call_host.dart`、`call_surface_state.dart`、`picture_in_picture.dart`、`app_navigation.dart`、`notify/CallNotification.kt`、`call_backdrop/call_visuals` 大改 | `MainActivity`：`setCallActive`/`enterPictureInPicture`/`setCallScreen`/`leaveCallToLock` 4 个 case + `onUserLeaveHint`/`onPause`/`onResume`/`popSystemNavigator` 4 处生命周期；Manifest `supportsPictureInPicture`、MODIFY_AUDIO_SETTINGS | `voice_call_page.dart` 802/214（**高**）；`voice_call.dart` 254 行（**高**）；`root_gate.dart`/`page_frame.dart`（低） |
| 设置页 | `graded_slider_tile.dart`、`choice_list_page.dart`、`mic_capture_section.dart`、`call_boost_section.dart`、`voiceprint_section.dart`、各诊断页 | 设置入口 1 行 | `voice_settings_page.dart` 1017/778（**高**）；`settings_widgets.dart` 693/615（**高**）；`speech_settings.dart` 425/261（**高**）；l10n parts（低，生成器兜底） |
| 诊断/取证 | `speech_diagnostics_page`、`speech_self_test_page`、`screen_test_page`、`voice_level_meter`、`SpeakerScreenTest.kt`、`scripted_conversation.dart`、`tool/wake_probe.dart` | `dsh/speech` probe/screenTest 方法 | `SpeechPlugin.kt`（**高**） |
| 构建 | `tool/build_apk.sh`、`.gitignore` 1 行 | — | `gradle.properties`（**高**，且已混入 CRLF，须归一） |

重构优先级（把 C 区往 A 区搬，按收益/风险排序）：

1. **拆 `SpeechPlugin.kt`**：按通道域拆成上游域（11 方法原样）+ fork 域
   （voiceprint/aec/probe/screenTest 各自成 channel handler 或独立文件），一次性把
   最大的冲突面变成挂点。
2. **`CallSettings` 字段外移评估**：10 个 fork 字段挪到 fork 自己的 settings
   provider（存储键迁移要带版本兼容），或至少在登记表标红人工核对。
3. **设置页收口**：新卡片已基本独立文件；`settings_widgets.dart` 的 693 行改动
   复核哪些可回退/收窄。
4. **`gradle.properties` 归一 LF** 后只保留必要键，注释精简。

---

## 4. 提交与同步流程

1. **一个模块一条线**：commit 用 conventional scope（`feat(wake):`、`fix(aec):`，
   现有历史已自觉遵守，规范化即可）；一个 commit 一件事，纯搬移与逻辑改动分开
   （沿用 refactor-2026-11.md 原则）。
2. **上游同步 SOP**：
   - `git fetch` → 跑模块测试基线 → `git merge upstream/main`（不 rebase 长历史）；
   - 冲突按 §3 登记表逐行核对；解完逐文件 `git grep "fork("` 确认挂点齐全；
   - 跑：`flutter analyze` + 模块测试 + Kotlin 单测；原生改动一律标注"未真机"；
   - 按模块分 commit 提交；同步前后打 `archive/*` tag。
3. **验证矩阵**（模块→必跑）：
   - Dart 逻辑：`flutter test test/speech test/state`；
   - 架构守卫：`test/arch/import_direction_test.dart`（非 ui 不 import ui）；
   - Kotlin：`testArm64DebugUnitTest --tests "*SoftwareAecTest" "*KaldiFbankTest" "*SpeechGateTest"`；
   - 构建：`tool/build_apk.sh`（AOT 预跑 + 6 分钟超时内）；
   - 真机：按各模块 handoff 的场景清单（语音相关模拟器测不出来）。

---

## 5. 合规检查单（每个 PR/commit 自查）

- [ ] 新功能放新文件了吗？在上游文件的落点每处 <~50 行并打 `fork(<module>)` 标记了吗？
- [ ] 通道是复用上游还是新开？方法名有模块语义吗？旧参数/旧方法语义没动吧？
- [ ] 模块开关默认值是什么？关闭时行为与上游一致吗？有测试钉住吗？
- [ ] fork 的 state 放自己的文件了吗？有没有往上游类里加字段？
- [ ] 动了共享 fakes / 共享测试文件吗？只加不改吗？
- [ ] 行尾是 LF 吗（`git ls-files --eol` 检查）？
- [ ] 新资产四件套（URL/SHA-256/大小/LICENSE）齐了吗？
- [ ] 文案走了 `parts/*.arb` 中英同步吗？生成物没手改吧？
- [ ] 提交是单模块 conventional scope 吗？
- [ ] handoff 文档更新了吗（已确认/已排除/未解决三段 + 决策点）？

---

## 6. 与既有规范的关系

- 与 `refactor-2026-11.md`（性能/依赖方向/运行时重构）并行不冲突：该方案的避让清单、
  "先有守卫再动"、"不夹带"原则全部沿用；本文件补的是 **fork 对上游** 的维度，
  它管的是"上游来了怎么接"，前者管的是"内部怎么整"。
- 仓库 AGENTS.md 硬规则全部继承：不接受外部 PR、main 只做锚点、不手改生成物、
  真机验证如实标注、双语同步。
