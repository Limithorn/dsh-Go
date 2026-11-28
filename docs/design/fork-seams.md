# fork-seams：上游接触面登记表

> 依据 `fork-modularity-standard.md` §3，MIC-94 首版（2026-11-28）。
> 基准：`fix/mic-source-unify` 对 `main` 的全量 diff（基点 `db854f6f7`）；表中 ± 行数 = `git diff --numstat origin/main...HEAD` 实测。
> **用法**：每次 `git merge upstream/main` 后，按本表逐行核对 B / C 列文件；解冲突后 `git grep "fork("` 复核标记齐全；逐模块跑测试、分模块提交（SOP 见规范 §4）。
> **维护规则**：A 区新文件零冲突、不需登记；B / C 每一处新增或移动都必须随同一 PR 登记进本表；每次上游同步后回填实际冲突情况。

---

## 1. 九个语音功能域登记表

| # | 模块 | 自有区 A | 上游挂点 B（重构落地时打 `fork(<module>)` 标记） | 共享区热点 C（± vs main，热度） | 关闭时行为（R4） | 不做它会怎样 |
|---|---|---|---|---|---|---|
| 01 | 离线 TTS（Kokoro） | `app/lib/speech/local_tts.dart`（+297，`dsh-tts` isolate 协议自成一体） | `app/lib/companion/companion_voice_source.dart` 枚举 + fetch 分支；`app.dart` import + 预热 `warmLocalTts()`（:103）；l10n `parts/speech_*.arb` | `companion_voice_source.dart`（低；与 02 共用同一挂点） | 声音源选回系统/Edge，行为与上游一致 | 少一个本地离线音源；下载/校验链路不存在；其余声音源无感 |
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

- **fork(...) 打标：0 处。** 分支上尚无 R2 格式的挂点标记（`DshFlutterEngine.kt:58` 有说明注释但未按格式打标）。打标随各功能点重构任务（MIC-95~103）落地，落地时回填本表。
- **行尾：64 个 CRLF 文件已归一**（独立提交，仅改行尾）；`.gitattributes` 补 `dart/kt/properties/gradle` 及实际出现 CRLF 的 `yml/json/arb/sh/txt/LICENSE` 规则；patch/diff 类 `-text` 条目原样保留。
- 表中 ± 行数以 `origin/main`（基点 `db854f6f7`）为参照；每次同步后如冲突热度与实际不符，勘误保留、不删行。
