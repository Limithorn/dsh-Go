# 通话形态（收起卡片 / PiP / 锁屏 / 常驻通知）handoff

> MIC-101，2026-11-28。基线：self-dev `9d6ac0851`（= 上游 main `c4b6f4810` + MIC-94 地基）。
> 参考实现：`fix/mic-source-unify`（该线上 `voice_call_page.dart` +802/−214、
> `voice_call.dart` +193/−61）。本模块把它在自研分支重建为 A 区组件 + 最小挂点，
> 同时保住上游 `voice_call_page.dart` 的既有功能（backdrop 三分支、伙伴房间通话、
> verbatimInput 逐字模式、iOS 文案分支、liveWordsModel 字幕链、`_shows` 去重、
> image 存在性缓存、`companionSessions` watch——这些全部核对过与上游 HEAD 逐段一致）。

## 已确认（带验证）

**架构**：`VoiceCallController` 归宿主单例 `VoiceCallHost`（`state/voice_call_host.dart`，
纯状态、不 import ui——比参考实现更严：参考版 state→ui 的 import 会撞
`test/arch/import_direction_test.dart` 的方向守卫，展开/推页动作反转给
`ui/speech/call/call_card_layer.dart` 与 `voice_call_page.dart`，宿主只搬状态）。

- 收起 = pop 全屏路由 + 卡片挂 RootGate 的 `CallCardLayer`（`root_gate.dart` 一处包裹）。
- 点卡片 = `host.expanding()` + 卡片层重新 push 复用同一控制器；计时从
  `controller.startedAt` 起算（`voice_call.dart` +3 行小增量），展开不掉回 `--:--`。
- 会话只解析一次：`chat_call.dart` 的 `PinnedSession`——发起页 pop 之后不再回问它。
- 发不出去的句子先持有再补发（`_pendingSend`/`_retrySend`，12 次 ×900ms 后才报
  `CallSendFailed`），不再每段噪声都「没发出去，再说一次」。
- PiP：Android 12+ `setCallActive` 预置 `autoEnter`（`onUserLeaveHint` 再调就晚了）；
  `popSystemNavigator` 兜底；`pictureInPictureChanged` 通知 Dart 换简版布局
  （`CallPipView`，动态光球 + 一句状态，无按钮——小窗单击被系统拿走）；
  进小窗前收掉 root Navigator 上的弹层（`_closeSheets`，"小窗怎么是设置页"的教训）。
- 锁屏：`callScreenLocked` 由原生 KeyguardManager 判断（showWhenLocked 时 Activity
  resumed，Dart 收不到 onPause，判不准）；`leaveCallToLock` 收起时撤 flag，一次返回回
  锁屏；`setCallScreen` 锁竖屏 + PROXIMITY_SCREEN_OFF 贴耳熄屏。
- 音量：通话中音量键指媒体流（Pixel 通话音量 7 与 1 输出功率相同的实测结论），
  挂断还原；`MODIFY_AUDIO_SETTINGS` 必须有（否则 setMode 静默失败、免提键无效）。
- 通知：`notify/CallNotification.kt` 常驻"语音通话中"，点它回 App，挂断撤销；
  文案在模块自有 `res/values*/call_strings.xml`（照 wake_strings.xml 模式，不进共享
  i18n_strings.xml）。
- 页面不再因「切到后台」主动结束通话（`didChangeAppLifecycleState` 留空）——
  锁屏叫醒后一秒就退的老 bug 的根治点；真正不可用时采集报 mic_busy 如实结束。

**验证（实际执行的命令与结果，macOS arm64 本机）**：

- `flutter analyze`（app/）：**No issues found**。
- `flutter test test/speech/call_card_controls_test.dart test/speech/collapsed_call_flow_test.dart
  test/speech/collapsed_card_hit_test.dart test/state/call_surface_state_test.dart`：
  **全绿**（收起后他处可点、拖动不出屏、计时接着走、PinnedSession、补发、PiP 事件
  监听不随页面走、原生通话标志、小窗动态光球/光晕/底片、收起弹回读原因等 29 条）。
- `flutter test test/speech/voice_call_test.dart test/speech/voice_call_page_test.dart
  test/shell/root_gate_autostart_test.dart`：**全绿**（上游自己的控制器/页面/根门
  测试无回归——中途修过一次：`_shows()` 去重必须保留，纯麦克风电平不重建页面）。
- `flutter test test/speech test/state test/arch`：**全绿**（含
  `import_direction_test.dart`：state→ui 零新增边，为此加了 `voice_state.dart`
  的 `VoicePermissionGranted` extension）。
- `flutter test test/common test/shell`：**+335 / −66，失败集合与基线（干净
  9d6ac0851 工作树同跑）逐条一致**——66 条全是本机渲染环境的既有 golden 失败
  （MIC-94 报告的约 1009 条机器基线的一部分），零新增。
- `gradle :app:compileArm64DebugKotlin`：
  **编译通过**（MainActivity 5 个 case + 生命周期、CallNotification、Manifest）。
- `gradle :app:testArm64DebugUnitTest`：**2495 例，7 失败**（ProotTempFilesTest /
  L2sMigrationTest，文件系统环境差异），**与基线同一组 7 条逐条一致，零新增**。
- `python3 app/tool/l10n_merge.py --check`：79 parts / 8994 keys 通过。

## 已排除（别再走一遍）

- **参考实现里 state→ui 的 import**（`voice_call_host.dart` import `voice_call_page.dart`
  等）：在自研分支上直接撞 import_direction_test（只减不增的守卫）。宿主保持纯状态，
  推页/展开反转到 ui 层，行为与测试语义不变。
- **参考实现删掉的 `_shows()` 去重**：上游测试钉住"纯麦克风电平不重建页面"，
  删了必红。保留上游去重 + fork 的 `_collapsed`/`_scheduleLeave` 逻辑合并。
- **参考实现的 `callStatus` 丢了 iOS 文案分支**（`wordsForIos` → iosSpeechCallEnd*）：
  上游有 iOS 分支，抽到 `call_card.dart` 时补回。
- **参考实现把 `call_visuals.dart` 的三处上游性能活儿退回去了**（光晕渐变代替宽
  mask 模糊、8 层描边、CallClock 60fps 截流）：那是上游 perf/call-light-cost 的成果，
  不是本模块需要的。只加 `strength`/`opaque`/`halo` 三个加法参数（小窗需要），
  性能结构原样保留。
- **参考实现的 `streaming_asr_model_state` 字幕链改写**：上游已换成 `liveWordsModel(ref)`
  + `onFailure`，保留上游版；本模块只加 `start:` 参数（宿主已启动过的通话不再启动）。
- **`page_frame.dart` 的 `showLargeTitle`**：核查后发现消费者是 forum/tavern/web/诊断页，
  与通话模块无关，不搬（登记表已更正）。
- **`pushScriptedTestCall`**：属 MIC-103 的 scripted_conversation，未搬。
- 参考实现的 `app.dart`/`app_info.dart` 改动属唤醒词域（MIC-100），未搬。

## 未解决 / 决策点

1. **真机全链路未做**（语音相关模拟器测不出来，本机只跑了 Dart 侧）：通话→收起→
   他处可点→展开（计时接着走）→PiP→锁屏叫醒→挂断通知撤销；音量键通话中调媒体流；
   贴耳熄屏；一次返回回锁屏（leaveCallToLock）。落地后按本清单逐条过。
2. **D1（verbatimInput 逐字模式落点）——拍板：维持上游形态，不引入新挂点。**
   上游 HEAD 的 `verbatimInput` 本来就是 `VoiceCallController` 的一个可选参数
   （`speech/call/voice_call.dart:101`，`conversation.send()` 时决定送逐字文本还是
   带提示词的整句），页面构造控制器的地方从 `widget.conversation` 读 `room.fullMode`。
   host 架构下构造点从页面挪到 `makeChatCallController`（voice_call_host.dart），
   同一个 switch 原样搬过去；页面自有 controller 的测试路径（`_mine`）也保留同款
   接线。逐字判断逻辑本身零改动——上游怎么变我们怎么跟。
3. **D3（PiP/CallNotification 与上游 CompanionAlwaysOnService 两套保活并存）——
   拍板：并存，不合并。** 依据（上游 HEAD 实读）：`CompanionAlwaysOnService` 持
   `PARTIAL_WAKE_LOCK`、跑通知回复（RemoteInput）那条链，保的是"引擎活着可回话"；
   通话侧保的是"Activity 可见→麦克风不被系统掐"（PiP 里 Activity 仍算可见）+
   一条 tap-to-return 的 ongoing 通知（非前台服务）。两者唤醒锁类型、通知渠道
   （`dsh-call` 3092 vs 会话通知）、目的互不重叠，同时运行无资源冲突；合并反而把
   通话模块耦合到上游的常驻对话功能上。通话开始时只停朗读（readAloud.stop，上游
   原行为），不动常驻对话服务。
4. **`VoiceCallController.backgrounded()` 成为无调用方**：页面不再因后台化主动结束
   （PiP/锁屏/前台服务撑麦的场景下这个判断是误伤源）。方法保留（上游原生代码，
   删掉是更大的上游 delta），CallEnd.background 的文案与处理链也保留；若上游日后
   给它新调用方，跟着上游走。
5. **参考实现未搬、留给后续模块的行为**（不是缺陷，是划界）：
   `utterance_dropped`（想/说期间的非插话段丢弃，防"识别失败"提示反复跳）与
   8 秒 TTS 看门狗（`_voiceWatch`，MIC-103 点名"已加、根因没查"）未随本模块搬运；
   `sensitivity`/`voiceprint*`/`callMicSource` 等字段与 `speech_fakes.dart` 的
   startCall 扩参未搬（MIC-97/99/102 落地时各自加，共享 fakes 届时仍遵守 R7 只加不改）。
   落地方式：哪个模块要哪个行为，从参考实现取那一段，别整文件覆盖。
