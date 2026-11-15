# 唤醒与悬浮通话：让通话住进桌宠

2026-11-15。这份设计把两件事合到一条线上：**免手唤醒**，以及**通话不再占满屏幕**。
两件事共用同一个前提——麦克风要在 App 不在前台时仍然可用，所以它们不是两个功能，
是一次窗口与音频所有权的重构。

现状的三条边界各自独立，但指向同一个缺口：

| 现状 | 位置 | 限制 |
|---|---|---|
| 通话页是全屏路由 | `ui/speech/voice_call_page.dart` `openChatCall` | `opaque: true`、`fullscreenDialog: true`，进去就盖住一切 |
| 切后台即挂断 | 同上 `didChangeAppLifecycleState` → `_call.backgrounded()` | 注释写明「Android 不给后台应用麦克风，硬撑只会录到静音」 |
| 悬浮伙伴不接语音 | `docs/design/companion-floating.md` §舞台协议 | float 模式「不接房间触摸、语音、道具、昼夜计时或自动情绪事件」 |

第三行是关键：悬浮伙伴当初**故意**摘掉语音，为的是省电和稳定。要做通话，不是接线，
是给 float 增开一个受控的通话态。

## 1. 已经铺好的部分

不重复造东西，先把可复用的列清楚：

- `VoiceCallController`（`speech/call/voice_call.dart`）不依赖任何 widget 或页面跳转。
  它只认三个抽象：`CallConversation`（发消息、收回复、打断）、`VoiceCloud`（识别）、
  `SpeechOut`（一次回答的声音）。`docs/design/voice-speech.md` §8 已经把「伙伴小屋的通话模式」
  写成「接一个伙伴版 `CallConversation` 即可」，本设计走的就是这条路。
- 悬浮的她和全屏页背景的她**是同一个页面**：`pet/CompanionFloatView.kt` 用 WebView 加载
  companion 舞台，通话页背景走 `CompanionStageController`，喂的都是 `assets/companion/stage.js`。
- `stage.js` 早就留了口型接口：`life.mouthOverride`、`life.voice.levels`（注释写「真实音频电平，给了就用」）、
  `life.speech`（按文本节奏），以及一整套表情。通话页现在每 50 ms 把电平塞进 `command('mouth')`。
- `pet/AskBar.kt` 已经是贴在桌宠旁的输入条，能把话发到当前对话或新对话，带语音录制入口。
- `MicArbiter` 已有，当前管两方：输入框听写、插件听声。唤醒是第三方，扩进去即可。
- `sherpa_onnx` 1.13.4 已在依赖里（四个 ABI 全打），KeywordSpotter 就在同一个库里，不需要新依赖。
- 前台服务、通知、`FOREGROUND_SERVICE`、`RECORD_AUDIO`、`WAKE_LOCK` 都已在 manifest 里。

## 2. 目标：三态一源

同一个角色，同一份状态，三种形态：

| 形态 | 内容 | 何时 |
|---|---|---|
| 悬浮 | 只有她，一个状态指示 | 默认；桌面上、别的应用上面 |
| 展开 | 她 + 一行字幕 + 静音/挂断 | 通话中，从悬浮点开 |
| 全屏 | 现在这一页，几乎不改 | 主动打开对话式通话 |

核心约定：**通话状态只有一个源**，在 `VoiceCallController`。三种形态都是它的渲染，
不允许任何形态自己维护一份通话状态。

## 3. 状态所有权

按 `docs/architecture.md` §2.3：跨页状态放 `lib/state/`，UI 不新造全局状态。

**已完成（第一期第一步）**：`CompanionStageController` 与 `CompanionStageEvents` 从
`ui/companion/companion_stage.dart` 拆到 `lib/companion/companion_stage_commands.dart`，原文件用
`export` 再导回去，16 处既有 import 不变。原因：`ui/` 以外不能 import `ui/`
（`test/arch/import_direction_test.dart` 守，只减不增），控制器留在 ui 里，`state/` 永远拿不到它。
同一改动把库私有的 `_web` / `_ready` 换成 `attach` / `markReady` / `detach`，语义限定为「只有持有
WebView 的舞台才调用」。

**一处修正**：不要把 controller 提到全局单例。一个 controller 只持有一个 `WebViewController`，
两处舞台（伙伴小屋页与通话页）同时活着时，后 `attach` 的会顶掉前一个，谁被顶掉就静默失声。

所以所有权拆成两层：

| 层 | 谁拥有 | 生命周期 |
|---|---|---|
| 通话状态（phase、电平、字幕行、surface） | `lib/state/` 的 provider | 与通话同寿，跨形态存活 |
| 渲染器（WebView 与它的 controller） | 各自的舞台 widget | 与页面同寿，互不共享 |

舞台订阅状态 provider，把状态翻成自己的 `command`。状态只有一份，渲染可以有多份，
但同一时刻只允许一个 surface 播放口型（见 §8 互斥规则）。

**踩过一次的坑**：surface 的登记/销号写在 `openChatCall` 里（进页面前 `set(full)`，`push`
返回后 `set(none)`），不在页面的 `initState` / `dispose` 里。在 `dispose` 里写 provider 会被
Riverpod 拒绝（`Tried to modify a provider...`），并连带把整页构建打挂。同一个函数里本来就有一行
`callChatProvider.set(null)`，是同一个时机、同一个 container，跟着它写就对了。

## 4. 舞台协议扩展

`companion-floating.md` 规定的原生 → JS 命令只有四个：`petState(state, reduceMotion)`、
`freeze`、`thaw`、`dispose`。本设计新增两条，且只在通话态生效：

| 新命令 | 参数 | 语义 |
|---|---|---|
| `callState(phase)` | `idle` / `listening` / `hearing` / `thinking` / `speaking` | 映射到已声明的表情与动作，见 §4.1 |
| `callLevel(value)` | `0..1` | 口型开合，仅在 `speaking` 时被接受 |

约束：

- 两条命令只影响舞台参数（`ParamMouthOpenY`、`ParamMouthForm`、表情），不改变窗口、不改模型、
  不触发房间里的道具与昼夜逻辑。
- 未收到过 `callState` 的页面忽略 `callLevel`，保证老页面、老 App 不受影响。
- 退出通话态时发一次 `callState(null)`，舞台回到宠物状态的表情，而不是 `calm`。

### 4.1 通话态到表情的映射

沿用 `companion-floating.md` 的原则：只用 `character.json` / adapter 声明过的 emotions 与 actions，
不存在的动作保持待机，不借房间通用动作表冒充模型能力。同状态重送不反复触发动作。

| 通话状态 | 表情（已声明时） | 一次动作（已声明时） |
|---|---|---|
| listening | calm | 无 |
| hearing | surprised | lookUp |
| thinking | confused | tilt |
| speaking | happy | nodSmall |

`attention` / `notification` / `error` / `sleeping` 等宠物状态在通话期间不覆盖，
通话态优先；通话结束后回到宠物状态机当前的状态。

## 5. 帧预算与耗电

`companion-floating.md` 给 float 定了上限：每次提交间隔至少 `1000/30 − 2` 毫秒，
像素读回每次提交执行一次，视口最高 640 view px，DPR 上限 4，`maxTexture=2048`。
口型每 50 ms 一次，落在 30 fps 以内，不改这个上限。

真正的代价不是帧率，是**从「说话才渲染」变成「持续渲染」**。现在的策略是：
折叠 / 变暗、屏幕关、省电、截图时 `freeze`，只有变化时才画。通话态会打破它。

处理原则：

- 通话态期间不 `freeze`，但保持 30 fps 上限，不上调。
- `callLevel` 只在 `speaking` 时推，其余阶段维持静息呼吸，不额外发包。
- 熄屏、省电、截图仍然走释放路径，通话那一路由麦克风前台服务独立存活，
  屏幕回来时重建 renderer 并重发一次 `callState`。
- 页面重建后第一帧必须是当前状态，不播入场动作，避免"接电话时她还在伸懒腰"。

这些数字都是工程上限，不是功耗保证；真机结论必须在真机上取。

## 6. 麦克风与唤醒

这一块是所有形态的前提。分三个持有者，用一个仲裁器：

```
唤醒服务（常开，KWS）
   ↓ 命中
通话采集（CallCapture，独占）
   ↓ 让出
输入框听写 / 插件听声（现有）
```

`MicArbiter` 现在只区分 dictation 与 plugin，需要扩成三方。规则：

1. 通话采集优先级最高；它开始时，唤醒服务**停采**但仍活着（保留模型与前台服务）。
2. 唤醒命中时若通话正在进行，忽略，不打断。
3. 听写与插件听声维持现有规则：听写让插件先停；唤醒服务在这两者占用时停采。

技术选型（与 `voice-speech.md` 的端上判停一致，全部在手机上跑）：

- 关键词检测用 sherpa-onnx `KeywordSpotter`，模型选 zipformer 中英混合的小模型，
  16 kHz 单声道，单线程推理，两秒内重复命中抑制。
- 命中后不直接开麦，先播一个固定确认音（不进对话历史、不进模型上下文），再进通话。
- 唤醒服务用 `microphone` 类型的前台服务，不是现在的 `specialUse`。

### 6.1 必须先在真机验的三件事

`docs/architecture.md` §6 第 6 条：手机操控、PRoot、直接启动、更新安装必须真机验证。
唤醒服务属于同一类，桌面测试不能替代。

1. **Android 14 的前台服务麦克风限制**：需要 `FOREGROUND_SERVICE_MICROPHONE` 权限与
   `microphone` 服务类型；后台启动受约束，重启后自启会被拦。这条决定方案能否成立。
2. **耗电**：常开 16 kHz 采音加 KWS 推理，连续挂 8 小时的实测曲线。
3. **回声自触**：外放时唤醒模型会不会被她自己的声音触发。`CallCapture` 已开平台 AEC，
   唤醒那一路需要同样的处理。

## 7. 分期

按可独立验证的顺序切，每期都能单独回退。

**第一期：状态解耦，不动窗口。**
把 `CompanionStageController` 移到 `lib/companion/`，新增 `state/call_stage_state.dart`，
全屏页改为读 provider 而不是自己 new。纯 Dart，跑 `flutter analyze` 与现有测试即可验证。
这一期结束时用户看不出任何变化。

**第二期：展开态。**
通话页加一个收起的形态，退成底部一条（状态、时长、静音、挂断），点开回全屏。
仍不跨应用，但把"通话可以离开页面"这件事立起来。

**第三期：悬浮态接指令。**
给 `CompanionFloatView` 加 `callState` / `callLevel` 通道，悬浮的她能跟着通话状态变表情、
开口型；`AskBar` 兼作字幕行。这一期结束，"通话住进桌宠"成立，但仍在 App 前台。

**第四期：唤醒服务。**
新增麦克风前台服务与 KWS，扩 `MicArbiter` 为三方，命中后拉起展开态。
与第三期并行做也可以，前提是 §6.1 第一条验过。

**第五期：后台通话。**
把 `backgrounded()` 的挂断改成"交给前台服务继续"，这才是真正跨应用。
`voice-speech.md` §8 把「后台通话（前台服务）」列为后续，本设计把它排最后，
因为它的风险最高、依赖最多。

## 8. 未验证与已知风险

- Android 14 麦克风前台服务的限制只查了文档，没有真机结论。
- 悬浮窗口在省电策略下被杀的概率比原生 View 高，`CompanionFloatPolicy` 的恢复逻辑会被更频繁触发。
  通话期间被杀等于断线，需要一条明确的用户可见状态。
- Live2D 持续渲染的耗电没有实测；通话态是否会显著拉高整机功耗未知。
- 两个 WebView（悬浮 + 全屏）不能同时活着渲染同一份状态，互斥规则要在第二期就写死：
  同一时刻只有一个 surface 接受 `callState` / `callLevel`。
- 识别、判停、打断三套机制的延迟没有端到端实测（`voice-speech.md` §8 也写了「延迟没实测」）。
  唤醒会新增一段固定延迟（确认音），这一段的听感要在真机上定。

## 9. 一手资料

- `docs/design/voice-speech.md` §6（通话机制）、§8（未做清单）
- `docs/design/companion-floating.md`（float 的协议、状态映射、帧预算）
- `docs/architecture.md` §2.3（状态所有权）、§6（关键约束）、§7（改哪儿）
- `app/lib/speech/call/voice_call.dart`、`app/lib/ui/speech/voice_call_page.dart`
- `app/android/app/src/main/kotlin/.../speech/CallCapture.kt`、`.../nativemedia/NeuralGate.kt`、
  `.../nativemedia/MicArbiter.kt`、`.../pet/CompanionFloatView.kt`、`.../pet/AskBar.kt`
- `app/assets/companion/stage.js`
