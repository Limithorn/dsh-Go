# 语音参数逐条核对

> 待批注。每条下面留了 `批注：` 行，直接写你的判断即可。
>
> 核对依据：`app/lib/speech/speech_settings.dart`、`speech_audio.dart`、
> `app/android/.../nativemedia/Thresholds.kt`、`NeuralGate.kt`、`Voiceprint.kt`。
> 上游（dsh-go）只有 11 个字段，下面 10 项全是我们 fork 加的，改它们不碰上游。

---

## 链路总览

```
麦克风
  │
  ├─[1] callMicSource ── 用哪条 Android 音源（auto/communication/recognition）
  │
  ├─[2] micGain ──────── 乘多少倍（1.0~32.0）
  │
  ├─[3] voiceprintMic ── 多大声算「有人在说」（静默判据）
  │
  ├─[4] voiceprint ───── 声纹总开关（关了就只剩能量闸）
  │
  ├─[5] voiceprintLevel ─ 基线门槛（0.40 / 0.50 / 0.60 / 0.70）
  ├─[6] voiceprintBias ── 在基线上再加减（-0.20 ~ +0.20）
  ├─[7] sensitivity ───── 仅播放时再抬（-0.06 / 0 / +0.08）
  │
  └─[8] voiceprintOthers ─ 旁人说话怎么处置
```

---

## 1. `callMicSource`

**位置**：`speech_audio.dart:162`

**档位**：`auto`（默认）/ `communication` / `recognition`

**作用**：决定 `AudioRecord` 用哪个 `AudioSource` 打开麦克风。

| 档位 | Android 常量 | 特点 |
|---|---|---|
| communication | `VOICE_COMMUNICATION`(7) | 带 AEC + NS，自己播的声音不漏回来；但有的机器把人声也压掉 |
| recognition | `VOICE_RECOGNITION`(6) | 不降噪，电平通常更高，但回声会漏 |
| auto | 运行时量两路 1.5s | 识别比通话高 20dB 以上才换 |

**auto 的判据**：`MicSource.SWAP_DB = 20.0`

**涉及文件**：
- `MicSource.kt`（解析与测量）
- `SpeechPlugin.startCall()` / `screenTestStart`
- `VoiceprintRecorder`（录入时另走 `VoiceProfileSource`）

**已知问题**：与 `VoiceProfileSource` 是两套独立设置，可能不同分布。

批注：我在上个月的实测中发现，如果选 auto，验证阶段大概会卡4.5秒，这个用户体验不好，是不是可以改成固定，然后做成手动切换？

---

## 2. `micGain`

**位置**：`speech_settings.dart:228`

**范围**：1.0 ~ 32.0（默认 1.0）

**作用**：采集到的每个采样乘这个倍数，在算电平和判定之前生效。

**怎么来的**：设置页点「量一下」→ 录 3 秒 → 按 `-30dBFS RMS` 反推倍数。
段内峰值超过 0.6 时按峰值反推，两者取小。

**生效位置**（必须两处一致）：
- `CallCapture.capture()` 第 195 行
- `VoiceprintRecorder` 第 205 行

**为什么固定而不是自适应**：自适应归一化按段内最大值缩放，AI 说话时最大的是回声，会把它拉满、底噪一起抬上去。

**已知问题**：与 `voiceprintMic` 可能互相干扰（一个放大信号，一个压判据）。

批注：我确认两个不会互相干扰，因为增益是让信号更响，而voiceprintMic是判断阈值，两者不冲突

---

## 3. `voiceprintMic`

**位置**：`speech_audio.dart:180`

**档位**：

| 档位 | percentile | multiple | absoluteFloor | voicedFraction |
|---|---|---|---|---|
| normal（默认） | 0.20 | 4.0 | 1e-10 | 0.20 |
| quiet | 0.30 | 3.0 | 1e-11 | 0.15 |
| faint | 0.30 | 2.5 | 1e-12 | 0.12 |

**作用**：判定「这段音频里有没有人说话」。低于门槛的帧丢掉，不送进模型。

**映射**：Dart `voiceprintMic` → `silence` → `KaldiFbank.Silence`

**用途**：老手机、厚壳、AEC 削得狠的机器，人声本来就小，用 normal 会全被判成静默。

批注：这一部分按照你说的，micGain不影响它，因为两者是不同层面的，那这里的设置是不是应该变成自动检测，而不是让用户手动选择？

---

## 4. `voiceprint`

**位置**：`speech_settings.dart:147`

**默认**：`false`

**作用**：声纹总开关。关掉后只剩能量闸（谁说话都算）。

**推送**：`voice_call_host.dart:78` → `VoiceprintChannel.configure(enabled:)`

批注：它现在是默认关闭的？那默认怎么打断？

---

## 5. `voiceprintLevel`

**位置**：`Thresholds.kt:65`

**实际门槛值**（按闸不同，同一档位数值不同）：

| 档位 | BARGE（通话插话） | WAKE（唤醒） | TURN（断句） |
|---|---|---|---|
| loose | 0.40 | 0.60 | 0.50 |
| normal（默认） | 0.50 | **0.70** | 0.58 |
| strict | 0.60 | 0.80 | 0.68 |
| very_strict | 0.70 | 0.90 | — |

**多人时自动抬高**：

```
accept(N) = base + 0.045 × ln(N) + bias
```

1 人 → +0；5 人 → +0.072

**为什么 WAKE 更高**：唤醒没有播放、没有 AEC，音频和注册时接近，可以要求更严。

批注：那这里的数值是不是要重新设定？

---

## 6. `voiceprintBias`

**位置**：`speech_settings.dart:150`

**范围**：-0.20 ~ +0.20（默认 0）

**作用**：

```dart
accept = acceptFor(level, n) + bias
```

**问题**：档位之间只差 0.10，而 bias 能到 ±0.20，**能直接把一档调成另一档**。

批注：这个参数是谁用的？用户还是我们调试？

---

## 7. `sensitivity`

**位置**：`speech_audio.dart:99`

**档位**：`sensitive(-6)` / `normal(0)` / `guarded(+8)`（单位 dB）

**传递链**：

```
Dart sensitivity.offset
  → channel 'offset'
  → SpeechPlugin.bargeOffset
  → CallCapture.bargeOffset
  → gate.bargeOffset
```

**实际生效位置**（`NeuralGate.kt:72`）：

```kotlin
val offset = if (playing) bargeOffset * 0.01f else 0f
```

**关键：只在 `playing`（AI 正在说话）时生效**，否则为 0。

-6dB → -0.06 分，+8dB → +0.08 分

**已知问题**：设置页写「插话灵敏度」，但静音状态下说完全不参与。

批注：没错，这个按理说应该要一直生效，因为打断和声纹是两套系统，打断应该有自己的阈值。现在好像是混在一起了

---

## 8. `voiceprintOthers`

**位置**：`speech_settings.dart:148`

**默认**：`true`（旁人说话算打断）

**作用**：关掉后只认「自己」的声音，旁人说话不打断。

**判定**：`SpeakerGate` 把分数落在 YOU / OTHER / UNKNOWN 三档，BAND=0.08 是中间的缓冲带。

批注：

---

## 9. `voiceprintWake`

**位置**：`speech_settings.dart:153`

**默认**：`false`

**作用**：唤醒闸是否也走声纹。关掉后任何声音都能唤醒。

**为什么单独一个开关**：唤醒是常开被动监听，判定次数远多于通话。

批注：

---

## 10. `VoiceProfileSource`（不在 CallSettings 里）

**位置**：`voiceprint_store.dart:21`

**档位**：`call`（默认）/ `wake` / `raw` / `unprocessed`

**作用**：**录声纹模板**时用哪条音源。存在每个 `VoiceProfile` 里。

**与 `callMicSource` 的对应**：

```
VoiceProfileSource        CallMicSource
├─ call    → VC           ├─ communication → VC
├─ wake    → VR           ├─ recognition   → VR
├─ raw     → MIC          └─ auto
└─ unprocessed → UNPROCESSED
```

**已知问题**：录模板选 `wake`(VR)、判定 auto 选中 `communication`(VC)，两个分布对不上，余弦会掉。

批注：

---

## 附：我看到的待确认项汇总

| # | 问题 | 我的判断 | 你的批注 |
|---|---|---|---|
| A | bias 能覆盖一个档位差 | 应该只在调试用，不该给用户 | |
| B | sensitivity 只在播放时生效 | 疑似 bug，应该一直生效 | |
| C | 两套音源枚举 | 需要对齐，否则分布不一致 | |
| D | voiceprintMic 与 micGain | 不同层，不冲突（你说得对） | |
| E | auto 音源测 4.5 秒 | 体验代价大，可考虑默认固定 | |
| F | voiceprintLevel 数值 | 需要按实测重新标定 | |

---

**批注方式**：直接在每条的 `批注：` 后面写。写完给我，我按你的意见出修改清单。
