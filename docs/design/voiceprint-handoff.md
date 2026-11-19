# 声纹与回声消除：交接

这一轮从「外放时 AI 打断自己」开始，一路挖到声纹特征预处理少了一整步。
下面按**结论 → 证据 → 待办**排，方便接手的人直接往下走。

---

## 一、当前状态（截至 2026-11-20 01:15）

代码已全部提交，工作区干净，最新提交 `946e92858`。

**最后一个改动（CMN）刚在 Xperia 上装好，还没有实测数据。** 这是目前唯一
没有验证的改动，也是影响最大的一处——它把之前所有阈值调参都作废了。

---

## 二、设备与环境

| 项 | 值 |
|---|---|
| 开发机 | Windows（MINGW64 / Git Bash），47GB 内存，全 SSD |
| 测试机 A | **Pixel 4 / Android 13**（SDK 33），序列号 `99101FFAZ007WP`（已断开） |
| 测试机 B | **Sony Xperia 5 IV / Android 14**（SDK 34），序列号 `QV770CNME9`，**有锁屏密码** |
| JDK | `tools/jdk17`，**必须用它**，见「五、坑」 |
| 打包 | `app/tool/build_apk.sh [--install]`，约 4~5 分钟 |

**Xperia 是主要测试机**，它的音频链和 Pixel 完全不同，两个都要考虑。

---

## 三、已经查清的结论

### 3.1 声纹分数「飘」的根因：CMN 完全缺失

`app/android/app/src/main/kotlin/.../nativemedia/KaldiFbank.kt` 的
`compute()` 里，`subtractMean` 分支只把均值算进 `mean` 字段，**然后直接
返回，一个数都没减**。`applyMean()` 写好了但全项目从没被调用过。

后果不是「分数偏低」，而是**分数随音量乱飘**：模型训练输入是 CMN 之后的
分布，喂原始 fbank 等于整体偏移，偏移量由这段多响决定。实测同一轮里

```
0.227  0.750  0.317  0.701  0.289  0.647
```

交替出现，而且**更安静的窗口反而拿高分**——它们的偏移恰好落进模型熟悉的
那片区域。

**已修**（`946e92858`）：改为段内均值归一化（per-utterance CMN），这是
Kaldi xvector 的标准做法，对音量/音源/麦克风增益都不敏感，不需要先跑语料
求全局均值。

> ⚠️ **这处改动之后，之前所有阈值、`playingBoost`、`voicedFraction` 门槛
> 都是在错数据上调的，需要重新校准。** 详见「四、待办」。

### 3.2 起音瞬态导致「刚开头必判成本人」

`AudioRecord` 启动后前 100~200ms 有一段强瞬态。把实景测试的录音拉下来
逐帧看：

```
  0ms    -35.6  -41.3  -52.4  -61.9  -65.2   ← 起手 -35.6 然后急降
100ms    -63.9  -58.2  -43.1  -36.5  -35.3
200ms    -39.1  -47.1  -52.8  -56.8  -59.4
...稳态在 -45 ~ -50
```

它有两个害处：

1. 把 `voicedFraction` 的 90 分位参考电平抬上去，让「够响」判定形同虚设
2. 本身成为 embedding 的主要成分——而**录入时它一样进了模板**，两边都含
   这段宽带噪声，余弦自然高

**已修**（`4e32c9be5` + `82dfcfd39`）：判定侧丢 400ms，录入侧丢 250ms。

> 已录好的模板里仍有这段噪声，**要重录才干净**（判定侧已丢，所以不会
> 再对上，重录是为了更准）。

### 3.3 空白段参与比对，导致「没说话也报 0.803」

`judge()` 把整整 1.5 秒窗口全送进 fbank，从不判断「这段有多少是声音」。
人只说 0.3 秒就停时，剩下 1.2 秒空白照样参与——**空白与空白算出的向量
几乎相同，余弦接近 1**。

**已修**（`45b93ea2e` + `e00167397`）：
- `SpeakerGate.voicedFraction()`：20ms 一帧算 RMS，取 **90 分位**当说话
  电平，数有多少帧落在其下 **25dB** 内，占比 < **0.15** 判无效
- 绝对电平下限 **-60dBFS**（只看相对分布不够——实测抓到过 p90=-77.4dB
  的窗口，内部起伏够大，voiced 照样算出 0.30）
- `embed()` 源头也拦：RMS < -65dBFS 直接返回 null
- 三处统一：`SpeakerGate.judge`、`Voiceprint.isKnownVoice`、实景测试

**注意**：实景测试那处是后来补的（`e00167397`）。当时说好三处统一，实景
测试漏了，于是整段全 0 的窗口照样算 embedding——出现 rms=-49.7 却拿 0.849
的窗口，拉下 wav 一看整段 -240dB（纯 0）。

### 3.4 播放时 UNKNOWN 被放行

回声经 AEC 削弱后分数正好落进 accept 与 reject 之间（实测 0.469，accept
0.531 / reject 0.451），判 UNKNOWN，而 `UNKNOWN -> START` 一律放行。

`UNKNOWN` 放行本来是为了修死锁（开口要结论、结论要攒够音频），但**播放时
这个理由不成立**——外人的声音不会因为我在播放而更难认。

**已修**（`e00167397`）：`UNKNOWN -> if (playing) NONE else START`。
空白段也从 UNKNOWN 改成 OTHER（UNKNOWN 会放行，拦不住）。

### 3.5 AEC 到底开没开：四层判断

一层不够。`AecSupport.kt` 分开记：

| 层 | 检查 | 说明 |
|---|---|---|
| ① | `AcousticEchoCanceler.isAvailable()` | 只说明 ROM 声称支持 |
| ② | `create(sessionId)` 非 null | 拿到 effect 对象 |
| ③ | `setEnabled(true)` 后读回 `enabled == true` | 真开了 |
| ④ | 音源自带 HAL 级 AEC | `VOICE_COMMUNICATION` 规范自带 |

**有效判据 = ③ 或 ④。** Android 13 上一般走 ③；14 上效果器常被挪进 audio
HAL，②③ 失败但 ④ 仍有效——只看「开没开」会把 14 误判成坏的。

**测 AEC 必须边放边测**：AEC 拿正在播放的音频当参考信号去减，不播放时它
没有参考可减，效果是恒等变换。之前「静默录三次」的测法完全无效，还得出
过「AEC 削了 35dB」的假结论（实际是麦克风没 warm up 的 -128dBFS 数字静默）。

现在用 `EchoTone` 放 200Hz→3.5kHz 扫频，媒体流满音量，同时录，与静默时
的电平相减。

**实测数据**：

| 设备 | VC | VR | MIC |
|---|---|---|---|
| Pixel 4 | **-74.1** | -20.8 | -27.5 |
| Xperia 5 IV | **-32.5** | -28.7 | -29.5 |

**Xperia 的通话音源正常**，没被降噪吃掉（Pixel 那台才有这个问题）。
所以 Sony 上的自打断**不是电平问题**。

### 3.6 已录声纹可回放

`VoiceprintRecorder` 存 `voiceprint-clips/vp-*.wav`，
`VoiceProfile.clipPath` 持久化，列表页给 ▶ 按钮。旧模板没有音频，不显示。

---

## 四、待办（按优先级）

### P0：验证 CMN 改动

新包装好后跑实景测试，看两个数：

1. **不说话时**分数是否稳定在低位（预期 0.1~0.3，不再乱跳）
2. **你说话时**分数是否稳定在高位（预期 0.6+，且明显高于不说话）

日志命令：

```bash
adb -s QV770CNME9 logcat -d | grep SpeakerScreenTest | tail -30
```

如果这两条成立，说明 CMN 修对了，进入 P1。

### P1：重新校准阈值

`Thresholds.kt` 里的 `baseFor()` 是按旧数据反推的：

```kotlin
Gate.BARGE 的数是按真机实测反推的：本人 0.45、旁人 0.2–0.4。
```

CMN 修好后这些数全部作废。需要重测：

- 本人说话的分数分布
- 旁人说话的分数分布
- 外放回声的分数分布

然后重设 `accept` / `reject` / `band`，并考虑 `playingBoost` 是否还需要。

### P2：录干净的模板

旧模板含起音瞬态。让用户重录一份，然后对比新旧模板的分数差异。

### P3：Xperia 上验 AEC 实测

到「回声消除诊断」点「量一遍」，看真实的回声漏量。目前只有 Pixel 的
数据（那边量测方法还是错的，要重跑）。

---

## 五、坑（环境相关，会重复踩）

### 编译卡死（已解决）

`flutter build` 会吃掉 Gradle 的真实错误，只留「卡住」。判断是否真在编译
**看有没有 java/cmake/ninja 子进程**，别只看进程活着。

真因：`HTTP(S)_PROXY=127.0.0.1:52762` 是本机代理，**Kotlin 编译 daemon
的 RMI 走本地 socket，被代理插一手就 Connection reset**。

修法：
- `app/android/gradle.properties` 加 `kotlin.compiler.execution.strategy=daemon`
- `build_apk.sh` 里 `NO_PROXY=localhost,127.0.0.1,::1`

排查时直接跑 `./gradlew :app:assembleArm64Release` 看完整堆栈。

### JDK

**必须用 `tools/jdk17`。** 机器上装了 JDK 21，AGP 在 21 上会无声卡死。

### Xperia 锁屏

有密码，adb 解不开（`input keyevent 82` 无效）。电量低时会限制后台，
`dumpsys battery | grep level` 查。充电时测试数据才可靠。

### 编译加速

已开 `org.gradle.parallel` / `caching` / `configureondemand`，`-Xmx4g`。
增量约 4~5 分钟，纯 Kotlin 增量约 50 秒。

---

## 六、关键文件

```
app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/
├── nativemedia/
│   ├── KaldiFbank.kt        ← CMN 在这里（P0 改动就在这）
│   ├── CampplusEmbedder.kt  ← fbank → 模型 → L2；静音门槛在这
│   ├── SpeakerGate.kt       ← 判定核心：voicedFraction、连续确认、UNKNOWN
│   └── Thresholds.kt        ← 阈值曲线（P1 要重校准）
└── speech/
    ├── AecSupport.kt        ← AEC 四层诊断 + 回声量测
    ├── EchoTone.kt          ← 扫频测试音
    ├── CallCapture.kt       ← 通话采集（音源可配）
    ├── VoiceprintRecorder.kt← 录入（丢 250ms 起音，存 wav）
    ├── SpeakerScreenTest.kt ← 实景测试（丢 400ms 起音）
    └── SpeechPlugin.kt      ← 通道入口

app/lib/
├── ui/settings/aec_diagnostics_page.dart   ← AEC 诊断页
├── ui/settings/screen_test_page.dart       ← 实景测试页
└── speech/voiceprint_store.dart            ← 模板存储（含 clipPath）
```

---

## 七、这一轮走的弯路（给接手的人省时间）

按时间顺序，这些都**不是**根因：

| 猜的 | 实际 |
|---|---|
| 内存不足 | 47GB 机器，可用 28GB |
| JDK 21 冲突 | 修了照样慢（但确实该修） |
| Gradle daemon 崩溃 | 是结果不是原因 |
| APK 副本堆积 | 清完照样卡 |
| 磁盘慢 | 全 SSD |
| 代理不可达 | curl 200、0.37s 正常 |
| 声纹阈值设太高 | 阈值是在错数据上调的 |

**最省时间的方法：拉录音逐帧看能量分布。** 好几处根因（起音瞬态、
全 0 窗口、CMN 缺失）都是这样看出来的。

```bash
adb -s <serial> shell ls -t /sdcard/Android/data/io.github.ccch1mneyyy.dsh_app/files/screen-test/
adb pull <path> ./
# 然后 20ms 一帧算 RMS(dB)，看分布
```
