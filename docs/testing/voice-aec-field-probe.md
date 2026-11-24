# 软件 AEC 单包真机验证计划

目的：在一个默认包上验证自建软件 AEC 能否消掉 AI 自己播放的声音，不再出现"说一半自己停"。**只有一个 APK，包名 `io.github.ccch1mneyyy.dsh_app`，覆盖安装，你的 API / 设置 / 声纹数据都保留。**

> 2026-11-24 晚的 A/B 双包验证前提没控制住：引擎超时时消息没发出去，没有真实 TTS，`play.pcm` 里只有提示音，量测数据作废。A/B 变体代码已删除，不再用双包对比。

## 0. 当前实现

`PcmStream.write()` 在把 PCM 写进 `AudioTrack` **之前**喂给 `SoftwareAec` 作参考；`CallCapture` 每 20 ms 把采集帧送进同一条参考时间轴，先互相关对齐 20–400 ms 的播放→回采时延，再用 1024 阶（64 ms）归一化 LMS 从采集里减掉回声，最后才做 `micGain`、电平、VAD/声纹判决。

播放轨 usage 固定 `USAGE_MEDIA`（软件 AEC 不依赖 HAL remap）；软件路径固定用 `VOICE_RECOGNITION`（不带 HAL AEC，Xperia 上电平比 `VOICE_COMMUNICATION` 高 53 dB），不挂系统 `AudioEffect`，避免两套消除器叠加。

| 文件 | 作用 |
|---|---|
| `speech/AecReference.kt` | 播放 PCM 环形缓冲、24 kHz→16 kHz 重采样、互相关时延对齐 |
| `speech/SoftwareAec.kt` | 双工感知的 NLMS 滤波器 + 单例开关/诊断状态 |
| `speech/CallCapture.kt` | 采集帧在增益与判决之前过 AEC |
| `speech/PcmStream.kt` | 写入 AudioTrack 前喂参考 |
| `speech/MicSource.kt` | 软件 AEC 下固定识别音源 |
| `ui/settings/aec_diagnostics_page.dart` | 「自建 AEC」开关与实时时延/削减量显示 |

开关：设置 → 语音设置 →「通话与采集」→「软件回声消除」（回声消除诊断页里也有一份）。默认开，状态持久化在 `software_aec` SharedPreferences；关掉后回到原系统 AEC 路径。快捷调用：`softwareAecStatus` / `softwareAecSet {enabled}`。

> **重要（2026-11-25 真机确认）**：AI 语音走 `dsh/companion_voice`（系统 TTS 或 `ClipPlayer` 播文件），**不经过 `PcmStream.write()`**，所以软件 AEC 的参考喂取点拿不到 AI 的声音——日志里 `softwareAec frames:0 / alignedFrames:0` 就是证据。当前 AI 说话时软件 AEC 实际不起效，设置开关只是让你能关掉它对比。

**同一通电话还暴露了自打断的真凶（已修）**：播放期间 `speakerJudge over:true kind:OTHER score≈0.09`——回声残差分数低于 reject，被判"他人"，而 `allowOthers=true` 时直接放行 → `speechStart over:true`。修复：`SpeakerGate.consume` 里播放期间的 OTHER 若分数低于 `reject × 0.5` 就当回声拦掉；真人在场分数高得多，仍可插话。

**离线验收**：`testArm64DebugUnitTest --tests "*SoftwareAecTest"`。合成 100 ms 延迟回声 + 安静房间，断言回声削减 > 10 dB、对齐到 100 ms ±5 ms、相关 > 0.7；另有一例验证无播放时采集帧逐字节不变。这条不依赖真机、引擎或环境噪声，**已通过**。

## 1. 构建与安装（只出一个包）

```bash
export PATH="/c/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/flutter/flutter/bin:$PATH"
export ANDROID_HOME="C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
cd <repo>
tooling/build-apk.sh --no-companion --no-star
# 产物：app/build/app/outputs/flutter-apk/app-arm64-release.apk
```

安装（覆盖默认包，数据不丢）：

```bash
adb install -r app/build/app/outputs/flutter-apk/app-arm64-release.apk
```

不再有 `--side` / `.test` 包；`BuildConfig.AEC_VARIANT` 已删除。

## 2. 取证怎么开

设置 → 回声消除诊断 →「取证（软件 AEC）」→「开始取证」。停止后文件在：

```
/sdcard/Android/data/io.github.ccch1mneyyy.dsh_app/files/voice-probe/<时间戳>/
├── call.pcm       通话采集流，16 kHz / mono / s16le，已过 AEC + micGain
├── play.pcm       TTS 播放流，采样率见 meta.json 的 playRate（通常 24 kHz）
├── events.jsonl   判决与状态事件，t 字段是相对起点的单调毫秒
└── meta.json      usage、音源、AEC 报告、机型、SDK
```

拉取与合成：

```bash
adb pull /sdcard/Android/data/io.github.ccch1mneyyy.dsh_app/files/voice-probe ./probe-soft
# playRate 从 meta.json 读；两路重采样到同一速率再混音
ffmpeg -f s16le -ar 16000 -ac 1 -i call.pcm \
       -f s16le -ar 24000 -ac 1 -i play.pcm \
       -filter_complex "[0:a]aresample=48000[a0];[1:a]aresample=48000[a1];[a0][a1]amix=inputs=2" out.wav
```

实时日志：`adb logcat -s DshProbe:I AecSupport:I SpeakerScreenTest:I CallCapture:I`

事件类型：`probeStart` / `configure` / `route` / `callStart` / `playStart` / `speechStart` / `speakerJudge` / `utterance` / `playEnd` / `callEnd` / `echoProbe` / `screenTestWindow` / `probeStop`。上限 60 MB 或 10 分钟，到了停写 PCM 但继续记事件。

## 3. 逐链路测试

### 3.1 AEC 实时状态（P0）

通话中、AI 正在说话时，诊断页看「自建 AEC」区：

| 读数 | 期望 |
|---|---|
| `enabled` / `active` | 都是 true |
| `delayMs` | 落在 20–400 ms（典型 60–150 ms） |
| `gainDb` | 持续播放时为正，稳定后 > 6 dB |
| `correlation` / `filterCorrelation` | > 0.5（参考和采集对得上） |

若 `delayMs` 为 0 或 `gainDb` 一直 ≤ 0：参考没喂进来或对齐失败，先查 `play.pcm` 是否有数据。

### 3.2 采集链路（P1）

打一通 20 秒电话，取证看 `configure` 事件的 `micOpened` 是否为 `VOICE_RECOGNITION`（软件 AEC 固定音源）；听 `call.pcm` 电平是否正常（Xperia 上 VC 曾 −61.8 dBFS，VR −20.8 dBFS，差距明显）。

### 3.3 播放路由与音量键（P0）

通话中、TTS 正在说话时：按音量键上/下，听声音是否变化；切听筒 ↔ 免提各一次，看 `route` 事件的 `mode` / `speaker` / `commActive`；确认声音真的从对应单元出来。

### 3.4 自打断（P0）

安静环境，让 AI 说一段 15–30 秒的长句，外放。重复 3 次。

- 统计 events 里 `speechStart.over=true` 的次数：理想为 0；
- 对照同时刻 `speakerJudge.kind/score`：若大量 `YOU` 且分数刚过门槛，是声纹门槛问题；若 `UNKNOWN`/`OTHER` 也放行，是 VAD/gate 问题；
- 若 `play.pcm` 有数据但 `call.pcm` 里听不到 AI 声音、且 `speakerJudge` 不再误判，说明 AEC 生效。

### 3.5 真人插话（P0）

播放中由本人和另一个人分别说固定句（如"停一下"）：本人应能打断（`speakerJudge=YOU` 后 `speechStart`）；他人是否打断取决于「他人打断」开关；记录从开口到 `speechStart` 的 `t` 差值。

### 3.6 声纹与静默检测（P1）

「声纹识别」开/关各跑一次 §3.4：关掉后 `speakerJudge` 应不再出现；「静默检测」三档各跑一次，保持不说话，看 `speechStart` 是否被静音误触发；`voiceprintWake` 开时喊唤醒词，确认唤醒链路仍能触发。

### 3.7 声纹录入（P2）

「录入音源」call / wake / raw 各录一条模板；每条都回放 `voiceprint-clips/vp-*.wav`，确认录进去的不是空白/纯回声。

### 3.8 实景测试（P1）

诊断页 / 语音设置里的实景测试入口，外放 TTS，跑 30 秒：每 1.5 秒一个 `screenTestWindow`，记录 `kind` / `rms` / `barged` / `source`；同时保存的 wav 在 `Android/data/<包名>/files/screen-test/`。

## 4. 记录表

```
机型 / Android 版本 / 构建版本号：
环境：安静 / 有背景人声；握姿：手持 / 桌面；外放音量档位：
delayMs = ___   gainDb = ___   相关 = ___
自打断次数 = ___/3    真人打断延迟 = ___ ms
音量键在通话中有效：是 / 否
结论：问题在 □非线性残余  □双工误学  □声纹门槛  □采集电平  □未定
取证目录：____________
```

## 5. 注意

- `aecEcho` 会把媒体音量拉满再恢复；测试前后确认音量档位一致。
- 取证目录会累积，测完及时 `adb pull`；不要在安装目录里手动删系统文件。
- 若关闭软件 AEC 后问题重现、打开后消失，即可确认根因是回声参考信号，而不是声纹门槛。
