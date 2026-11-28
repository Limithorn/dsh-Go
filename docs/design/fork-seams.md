# fork-seams：上游接触面登记表

> 依据 `fork-modularity-standard.md` §3，MIC-94 首版（2026-11-28）。
> 基准：`fix/mic-source-unify` 对 `main` 的全量 diff（基点 `db854f6f7`）；表中 ± 行数 = `git diff --numstat origin/main...HEAD` 实测。
> **用法**：每次 `git merge upstream/main` 后，按本表逐行核对 B / C 列文件；解冲突后 `git grep "fork("` 复核标记齐全；逐模块跑测试、分模块提交（SOP 见规范 §4）。
> **维护规则**：A 区新文件零冲突、不需登记；B / C 每一处新增或移动都必须随同一 PR 登记进本表；每次上游同步后回填实际冲突情况。

---

## 1. 九个语音功能域登记表

| # | 模块 | 自有区 A | 上游挂点 B（重构落地时打 `fork(<module>)` 标记） | 共享区热点 C（± vs main，热度） | 关闭时行为（R4） | 不做它会怎样 |
|---|---|---|---|---|---|---|
| 01 | 离线 TTS（Kokoro）·**2026-11-28 已落地 self-dev（MIC-95）** | `app/lib/speech/local_tts.dart`（+297 照搬；解包走 `Isolate.run`，加载/合成留主 isolate——后台 isolate 里 eSpeak 设嗓音 abort，见 `docs/design/local-tts-handoff.md`） | `companion_voice_source.dart`：枚举 +1 值、`localVoice` 字段（ctor/copyWith/plain/fromPlain）、`configured`、fetch `_local` 分支、`warmLocalTts()`——全部已打 `fork(tts)`；`app.dart`：import ×2 + initState 预热块；`companion_voice_page.dart`：import + initState 探测 + 音源列表 1 行 + 下载分区；`voice_settings_page.dart`：`speechVoiceLabel` 补 1 臂（枚举加值必改）；l10n `parts/companion_{zh,en}.arb` +6 键（ARB 是 JSON，无法内联打标，以本表代登记） | `companion_voice_source.dart`（低；与 02 共用同一挂点，02 落地时相邻行逐行核对） | 声音源选回 system/DeepSeek 等上游音源 → fetch 走上游分支，行为与上游一致；`localVoice` 随存档持久 | 少一个本地离线音源；下载/校验链路不存在；其余声音源无感 |
| 02 | Edge 云端 TTS | `app/lib/speech/edge_tts.dart`（+416，裸 websocket 协议） | 同 01：`companion_voice_source.dart` 枚举分支；设置页音色选择；l10n | 同 01（低） | 不可用/被关 → 回落其他声音源，错误可执行不静默 | 少一个免费云端音色源；协议失效风险随整模块消失 |
| 03 | 声纹门控 | `nativemedia/CampplusEmbedder.kt`、`KaldiFbank.kt`（+315）、`SpeakerGate.kt`（+514）、`Thresholds.kt`、`speech/Voiceprint.kt`（+359）；Dart：`speech/sherpa_speaker_embedder.dart`、`nativemedia/speaker_gate_bridge.dart`（+356） | `SpeechPlugin.createGate()` 挂接；`TurnGate.bargeOffset` 扩展 | **`SpeechPlugin.kt` +985/−332（高）**——voiceprint 域方法按 R3 拆 `dsh/voiceprint` 通道 | 关/无模板时逐帧完全直通（三条不变量第一条） | 无"只听本人"门控，唤醒/插话对所有说话人放行；04 的模板失去消费者 |
| 04 | 声纹录入、存储与诊断 | `speech/VoiceprintRecorder.kt`（+363）；`lib/speech/voiceprint_store.dart`（+290，加密存储）、`voiceprint_log.dart`；`ui/settings/voiceprint_enroll_page.dart`（+503）、`voiceprint_list_page.dart`（+205）、`voiceprint_entry_page.dart`、`voiceprint_diagnostics_page.dart`（+261） | 设置入口；l10n | **`SpeechPlugin.kt`（高，通道拆分与 03 协调）**；`app/test/speech/speech_fakes.dart` +10/−1（中，只加不改，R7） | 无模板 → 判定直通（与 03 衔接） | 无录入/管理界面；03 保持直通态即安全 |
| 05 | AEC 双路与音源统一（含 D4） | `speech/AecSupport.kt`（+517）、`SoftwareAec.kt`、`AecReference.kt`、`MicSource.kt`（+194）、`EchoTone.kt`、`VoiceProbe.kt`（+209）；`ui/settings/aec_diagnostics_page.dart`（+636） | `PcmStream.write()` 喂参考（时序敏感）；`CallCapture` 过 AEC（时序敏感）——两处人工核对 | **`SpeechPlugin.kt`（高，aec 域拆 `dsh/aec`）**；`CallCapture.kt` / `PcmStream.kt`（中，时序敏感）；D4：AI 语音不走 `PcmStream`，软件 AEC 当前实际无效 | 软件开关关 → 回系统 AEC 路径；`VoiceProbe` 默认关零开销 | 回声环境插话判定变脏（03 的输入）；两路音源各选各的、分数不可比 |
| 06 | 唤醒词（KWS + FGS） | `wake/` 整包（`WakePlugin.kt`、`WakeCapture.kt`、`WakeWordService.kt`）；`lib/speech/wake_word.dart`、`wake_pinyin`；`state/wake_state.dart`（+237）；`assets/wake/*`；`values*/wake_strings.xml` | `DshFlutterEngine.kt` `plugins.add` 一行（:58-60，现只有说明注释、未打标）；Manifest service+permission（`FOREGROUND_SERVICE_MICROPHONE`）；`app.dart` import + `navigatorKey`（:256） | 无（**整包范例**：A 区 + 三处单行挂点） | 默认关；关后 `dsh/wake` 无副作用、FGS 停止、通知撤销 | 无后台免接触唤起；从通知/图标进入不受影响 |
| 07 | 通话形态（卡片/PiP/锁屏/通知） | `state/voice_call_host.dart`（+708）、`call_surface_state.dart`、`picture_in_picture.dart`、`app_navigation.dart`；`notify/CallNotification.kt`；`ui/speech/call/call_backdrop.dart`（+582/−499）、`call_visuals.dart`（+528/−522）；测试 `call_card_controls_test.dart`（+618）、`collapsed_call_flow_test.dart`（+229）、`collapsed_card_hit_test.dart`、`call_surface_state_test.dart` | `MainActivity.kt`（+202/−3，中）：4 个 channel case + 4 处生命周期；`root_gate.dart` / `page_frame.dart`；Manifest 2 行 | **`ui/speech/voice_call_page.dart` +802/−214（高）**；`speech/call/voice_call.dart` +193/−61（高） | surface=none 时无全局卡片/通知，页面回上游形态 | 通话保持全屏页形态（无收起/PiP/锁屏唤起/常驻通知）；上游新功能不受影响 |
| 08 | 设置页与参数体系 | `ui/settings/graded_slider_tile.dart`、`choice_list_page.dart`、`mic_capture_section.dart`、`call_boost_section.dart`、`voiceprint_section.dart`（+201） | 设置入口 1 行；l10n `parts/speech_*.arb`（+448/−138，生成器兜底） | **`voice_settings_page.dart` +1017/−778（高）**；**`settings_widgets.dart` +693/−615（高）**；**`speech_settings.dart` +425/−261（高）**——`CallSettings` 10 个 fork 字段（`sensitivity`、`voiceprint`、`voiceprintWake`、`voiceprintLevel`、`voiceprintBias`、`voiceprintOthers`、`voiceprintAccept`、`callMicSource`、`voiceprintMic`、`micGain`）；`speech_audio.dart` +404/−201（中） | 总闸关 → 四卡置灰、下游无消费者；字段默认值 = 上游行为 | 无设置页改版，参数走上游默认；03/05 失去调参界面（通道不受影响） |
| 09 | 诊断取证与构建链 | `ui/settings/speech_diagnostics_page.dart`（+413）、`speech_self_test_page.dart`（+353）、`screen_test_page.dart`（+435）、`voice_diagnostics_page.dart`、`voice_level_meter`；`speech/SpeakerScreenTest.kt`（+310）；`lib/speech/call/scripted_conversation.dart`；`app/tool/build_apk.sh` | `dsh/speech` 的 probe/screenTest 方法（R3 拆 `dsh/probe`，与 03/05 协调先后） | **`SpeechPlugin.kt`（高）**；`app/android/gradle.properties` +39/−11（量小但每次同步必核对；CRLF 元凶已随 MIC-94 归一）；`build_apk.sh` 机器路径（低） | `VoiceProbe` 默认关 = 日常零开销 | 无分级诊断/实景测试/取证工具，排查靠日志；功能开发不受影响 |

---

## 2. 跨域共享热点（单文件冲突面排行）

| 文件 | ± vs main | 热度 | 归属与处理 |
|---|---|---|---|
| `speech/SpeechPlugin.kt` | +985/−332 | **高** | 03/04/05/09 共用 `dsh/speech`。第一优先重构：按 R3 拆 `dsh/voiceprint`、`dsh/aec`、`dsh/probe`，上游原 11 方法留 `dsh/speech` |
| `speech_settings.dart`（`CallSettings`） | +425/−261 | **高** | 08 负责字段外移评估（新键+版本兼容迁移）；其余域新增参数一律走 fork 自己的 provider（R5），不许再加字段 |
| `ui/settings/voice_settings_page.dart` | +1017/−778 | **高** | 08：四卡结构重排，同步时逐段人工核对 |
| `ui/settings/settings_widgets.dart` | +693/−615 | **高** | 08：复核哪些可收窄回上游版 |
| `ui/speech/voice_call_page.dart` | +802/−214 | **高** | 07：压成"上游骨架 + 自有组件装配" |
| `speech/call/voice_call.dart` | +193/−61 | 高 | 07 |
| `MainActivity.kt` | +202/−3 | 中 | 07：case 集中，R2 打标后可 grep |
| `app/test/speech/speech_fakes.dart` | +10/−1 | 中 | 全域共享测试协议：**只加不改**（R7） |
| `app/android/gradle.properties` | +39/−11 | 低量·必核对 | 09；CRLF 已归一（本任务），内容冲突仍需人工看 |
| `app/lib/l10n/parts/speech_*.arb` 及 gen | +448/−138 | 低 | 生成器兜底，中英同步走 `l10n_merge.py` |

> **勘误（2026-11-28，MIC-95 落地时发现；按规范 R10 勘误保留，不删原行）**：原行 01 的 B 列两处不准——
> ① l10n 挂点实际在 `parts/companion_*.arb`（TTS 文案域），非 `parts/speech_*.arb`；② 漏登两处真实挂点：
> `companion_voice_page.dart`（下载/进度/失败行内展示）与 `voice_settings_page.dart` 的 `speechVoiceLabel`
> （穷举 switch，枚举加值必补臂）。行 01 已按落地实况改写，勘误在此留痕。

---

## 3. 已探明的下一次同步冲突面（merge-tree 实测）

`main` 自基点 `db854f6f7` 前进到 `c4b6f4810`（+80 提交，240 文件，+14020/−937）。对该 tip 做 `git merge-tree --write-tree` 预演，**内容冲突 6 处**，全部命中上表 B/C 列：

| 冲突文件 | 命中行 | 说明 |
|---|---|---|
| `AndroidManifest.xml` | 06/07 的 Manifest 行 | 上游新增 service 与 fork 的 FGS/权限块相邻 |
| `DshFlutterEngine.kt` | 06 注册行（:58-60） | 上游在该文件 +28/−2，正好动注册区周围 |
| `MainActivity.kt` | 07 的 case/生命周期 | 上游 +3 |
| `speech/CallCapture.kt` | 05 的 AEC 接入 | 上游 +6/−1 |
| `app/lib/app.dart` | 01/06 的 import、预热、`navigatorKey` | 上游重构 App 入口 |
| `app/lib/state/app_info.dart` | 09 诊断字段 | fork 侧 CRLF 已随本任务归一，剩余为纯内容冲突 |

首次同步按规范 §4 SOP 执行：先跑基线 → merge → 按本表逐文件核对 → 逐模块测试、分模块提交 → `archive/*` tag。

### 2026-11-28 同步回填（MIC-105：self-dev 线落地）

**落点变更**：用户拍板工作线 = `self-dev`（2026-11-28）。self-dev 无本地提交，直接快进到 `origin/main`（`c4b6f4810`，含上游 80 个新提交），再 cherry-pick 地基提交（规范文档、`.gitattributes`、本登记表首版），行尾按新规则 `git add --renormalize` 重导出 19 个上游残留 CRLF 文件（仅改行尾）。**self-dev 线上没有 fork 代码**，因此上表 6 处冲突在此线全部不存在——它们是 fix 线（`fix/mic-source-unify`）合 main 时的事；fix 线保持为功能移植参考实现、不动，上表对 fix 线下次合并仍然有效。

**6 处冲突文件：上游 80 提交实际动了什么**（`git diff db854f6f7..c4b6f4810` 逐文件核对）：

| 文件 | 上游改动 | self-dev 落法 | 对移植任务（MIC-95~103）的意义 |
|---|---|---|---|
| `AndroidManifest.xml` | +10：新增 `RemoteBackgroundService`（FGS `specialUse\|location`，后台保活远程连接） | 上游原样（无 fork 块可保留） | 06/07 的 Manifest 挂点（`FOREGROUND_SERVICE_MICROPHONE` + 权限）以**独立 service 条目**并列落进同一区域，不与它共用块 |
| `DshFlutterEngine.kt` | +28/−2：`plugins.add` 重构（`val runtime = RuntimePlugin()`）＋内联注册新通道 `…/remote_background`（4 方法） | 上游原样 | **上游自己开始用「引擎工厂内联通道」模式**；06 的 wake 注册行落同一 `.also{}` 块，原 :58-60 行位已变 |
| `MainActivity.kt` | +3：`RemoteBackgroundService.onHostStarted/onHostStopped` 生命周期两处 | 上游原样 | 07 的 4 处生命周期挂点与这两处共存，移植时逐处核对 |
| `speech/CallCapture.kt` | +6/−1：静音期 `onLevel(0.0)` 只发一次（`mutedLevelSent` 去重） | 上游原样 | 05 的 AEC 接入点（增益/电平之前）不变，但电平消费语义变了——AEC/诊断移植后按新行为验证 |
| `app/lib/app.dart` | +12：`didHaveMemoryPressure`（PetSheets/BotAvatar 缓存回收）、`remoteBackgroundProvider` watch、3 个 import | 上游原样 | 01/06 的 app.dart 挂点（import、`warmLocalTts()`、`navigatorKey`）在重排后的文件上重新锚定 |
| `app/lib/state/app_info.dart` | +1/−1：版本默认值 `1.3.0+1` → `1.4.1+1` | 上游原样 | 09 诊断页引用的版本常量随上游走 |

**新触点核对结论**：上游 80 提交（240 文件，+14020/−937）**未触及 §2 任何一个高危热点**——`SpeechPlugin.kt`、`speech_settings.dart`（`CallSettings`）、`voice_settings_page.dart`、`settings_widgets.dart`、`voice_call_page.dart`、`voice_call.dart`、`gradle.properties`、`speech_fakes.dart`、`companion_voice_source.dart`、`PcmStream.kt` 全部 0 改动。新内容集中在已登记的 6 个 B 列挂点文件自身的上游侧前移（上表）＋fork 无关域（remote 后台服务、pet overlay、companion、workshop、非 speech 的 l10n parts、docs/guide）。speech 域仅有的上游小改：`deepseek_speech.dart` 零拷贝 yield（+2/−1）、`ui/speech/call/call_parts.dart` 的 `CaptionWindow` 改 stateful 缓存 TextPainter（+48/−15）、`test/speech/voice_call_page_test.dart` +22——**07 移植时须一并接住上游对该页新增的测试**。

**无需新增登记行**：新触点全部落在既有 B 列挂点文件上；无新插件文件、无新 Activity 分支、无新设置结构（`CallSettings` 零改动）。

---

## 4. MIC-94 验收覆盖对照

- [x] `SpeechPlugin.kt` — §1（03/04/05/09）、§2
- [x] `speech_settings.dart`（CallSettings 10 字段）— §1（08）、§2
- [x] `voice_settings_page.dart` — §1（08）、§2
- [x] `settings_widgets.dart` — §1（08）、§2
- [x] `voice_call_page.dart` — §1（07）、§2
- [x] `gradle.properties` — §1（09）、§2、§3
- [x] `speech_fakes.dart` — §1（04）、§2

---

## 5. 当前状态备注

- **fork(...) 打标：tts 域已打（MIC-95，`git grep "fork(tts)" 可列全）；其余域仍 0 处。** 打标随各功能点重构任务（MIC-96~103）落地，落地时回填本表。`DshFlutterEngine.kt:58` 仍只有说明注释、未按格式打标。
- **行尾：64 个 CRLF 文件已归一**（独立提交，仅改行尾）；`.gitattributes` 补 `dart/kt/properties/gradle` 及实际出现 CRLF 的 `yml/json/arb/sh/txt/LICENSE` 规则；patch/diff 类 `-text` 条目原样保留。
- 表中 ± 行数以 `origin/main`（基点 `db854f6f7`）为参照；每次同步后如冲突热度与实际不符，勘误保留、不删行。
- **2026-11-28 上游同步（MIC-105）已完成**：self-dev 线 = `c4b6f4810`（上游 80 提交）＋ 地基提交 ＋ 本回填；同步前后打 `archive/self-dev-{before,after}-sync-20261128` tag。self-dev 上 `fork(` 打标仍为 0 处（随 MIC-95~103 落地）；fix 线未动，仍为移植参考。
- 上游残留 CRLF：19 个文件已随同步按 `.gitattributes` 重导（独立提交，仅改行尾，`git diff --ignore-cr-at-eol` 为空证明）。
