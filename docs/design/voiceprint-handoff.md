# 声纹与回声消除：交接

> 更新于 2026-11-21 01:30。代码已回滚到 `c6708e3d7`，与 fork main 一致。
> **这一轮的核心收获不是修好了什么，而是搞清楚了几件「看起来像 A，
> 实际是 B」的事**——下面按「已确认 / 已排除 / 未解决」分开写，
> 免得接手的人重复踩。
>
> **2026-11-21 补记（音源统一）**：文中 §2.1、§2.3 两条结论**已经过期**，
> 修复都在当前 main 里（见各自的「已过期」框），§四 的 P0/P1 也已完成。
> main 现在不止 `c6708e3d7`，那条只是写作时的回滚点。这一轮新做的
> 「采集音源统一」写在 §八。

---

## 一、当前状态

| 项 | 值 |
|---|---|
| 代码位置 | `c6708e3d7`（`Limithorn/dsh-Go` main 同点） |
| 工作区 | 干净 |
| 声纹功能 | **可用但不准**，判定时分数不可靠 |
| 回滚前状态 | tag `archive-before-rollback-20261121`（`44d5d9411`） |
| 未提交改动 | `git stash` → `rollback-rescue-0126` |
| 测试机 | Sony Xperia 5 IV `QV770CNME9`（Android 14，有锁屏密码）/ Pixel 4 `99101FFAZ007WP` |

**回滚原因**：`44d5d9411` 那三个提交（CMVN、READ_BLOCKING、提示拆分）是在
错误判断下做的，而且 `READ_BLOCKING` 疑似让 Xperia 的录音动态范围掉到
1/40。代码留着会继续误导。

---

## 二、已确认的结论（有数据支撑）

### 2.1 声纹录入保存的是「同一个 buffer 的残影」——这是主因

> **已过期（2026-11-21 核实）**：`VoiceprintRecorder` 现在存的是拷贝
> （`synchronized(chunks) { chunks.add(buffer.copyOf(n)) }`，提交 `9d84ad42`），
> 残影问题不存在了。**下面这段仍然值得读**——它记的是当时怎么用
> 「唯一采样值 + 峰值」把问题钉死的，那套判据现在还在用。
> 但「这是主因」这句话对当前代码不成立，别再沿着它找 bug。

`VoiceprintRecorder` 的采集循环里：

```kotlin
val frame = if (kept == n) buffer else buffer.copyOf(kept)
chunks.add(frame)          // ← kept == n 时，存的是 buffer 本身
```

`buffer` 是循环里复用的同一个数组，每轮 `read()` 都会覆盖它。于是
`chunks` 里**所有元素指向同一块内存**——最终只留下最后一次读到的内容，
其余位置是那一轮没被覆盖的残留（通常是 0）。

**证据**（51 段真机录音全部统计）：

| 录音批次 | 唯一采样值 | 峰值 |
|---|---|---|
| 旧代码（正常） | 2076 ~ 4181 | 1499 ~ 3833 |
| 用了这段代码 | **16 ~ 287** | **9 ~ 1204** |
| 极端样本 | **1** | **0**（整段 82880 采样全 0） |

正常录音几千个不同采样值、峰值 3000 上下；出问题的只有几十个值。

日志里 `chunks=0 samples=0` 和 `chunks=301 samples=96320` **交替出现**，
也是同一个原因——取决于最后一次读到什么。

**判定「录音是不是好的」不能只看 loudness。** 实测一段 6 秒录音
`loudness=-62.9`，看着像「声音小」，实际整段只有 82 个不同采样值、
范围 `[-78, 34]`。要看 **唯一值个数 + 峰值**：

```
正常：unique > 1500, peak > 1200
异常：unique < 300,  peak < 1200
```

修复（回滚前已写好，在 stash 里）：

```kotlin
val frame = buffer.copyOf(kept)   // 每次都拷贝
```

### 2.2 「差别太大」这句提示骗了人

日志里真正发生的是：

```
KaldiFbank: count=600 voiced=0 need=72
```

**三段录音一帧人声都没检测出来**，`vectors` 是空的。但代码里
`vectors.isEmpty` 和 `worst < _minConsistency` 共用同一句提示，
于是「根本没录到人声」被说成「差别太大」，把人引向「再重说一遍」。

**这是 2.1 的下游症状**，不是独立问题。

### 2.3 CMN 确实只减了均值，没除标准差

> **已过期（2026-11-21 核实）**：CMN 已经落地，不用「重做」。
> `KaldiFbank.compute()` 现在逐维减去本段均值（`fr[k] = (fr[k] - m[k])`），
> `applyMean()` 也在推理路径上被调用了（提交 `a690e4b4`）。
> 下面的数据是**修复前**测的，留着当对照；「这个修复要重做」那句作废。

`KaldiFbank.compute()` 里原来是这样：

```kotlin
if (subtractMean) {
    val running = mean
    if (running == null) { mean = ...算均值... }
}
return out.toTypedArray()      // 算完就返回，一个数都没减
```

`applyMean()` 写了但全项目从没被调用过。这是真 bug，**与 2.1 无关**。

加上「减均值 + 除标准差」的对比数据：

| 版本 | CMVN 后 range |
|---|---|
| 只减均值 | **[-96.2, 65.0]** |
| 减均值 + 除标准差 | **[-15.8, 4.2]** |

差 8 倍。说明只减均值确实保留了动态范围（安静窗口跨度小、响的跨度大）。

**但这个修复要重做**——回滚把它一起带走了。重做时注意
`applyMean()` 的签名要同步改，否则两条路径分布不一致。

### 2.4 实景测试的窗口是 1.0 秒，不是 1.5 秒

```kotlin
windowSamples = WINDOW_MS / 1000 * RATE
              = 1500 / 1000 * 16000
              = 1 * 16000 = 16000     // 整数除法先截断再乘
```

注释里写着「和 SpeakerGate.WINDOW_MS 一致」，实际从来不一致。
录音文件 32044 字节 = 1.00 秒可以佐证（正常应是 48044 = 1.5 秒）。

**已修**（在 `c6708e3d7` 里，`WINDOW_MS * RATE / 1000`）。

### 2.5 AEC 四层判断，两个 Android 版本走不同路径

| 层 | 检查 | 说明 |
|---|---|---|
| ① | `AcousticEchoCanceler.isAvailable()` | 只说明 ROM 声称支持 |
| ② | `create(sessionId)` 非 null | 拿到 effect 对象 |
| ③ | `setEnabled(true)` 后读回 | 真开了 |
| ④ | 音源自带 HAL 级 AEC | `VOICE_COMMUNICATION` 规范自带 |

**有效判据 = ③ 或 ④。** Android 13 一般走 ③；14 常把效果器挪进 audio
HAL，②③ 失败但 ④ 仍有效——只看「开没开」会把 14 误判成坏的。

**测 AEC 必须边放边测**：AEC 拿正在播放的音频当参考去减，不播放时是
恒等变换。「静默录三次」的测法完全无效。

实测数据：

| 设备 | VC | VR | MIC |
|---|---|---|---|
| Pixel 4 | **-74.1** | -20.8 | -27.5 |
| Xperia 5 IV | **-32.5** | -28.7 | -29.5 |

**Pixel 的通话音源是废的**（-74dB），Xperia 正常。所以 Pixel 上实景测试
录出一片静默是设备特性，不是代码问题。

~~实景测试页已有音源切换可选。~~ **（2026-11-21 起已过期）** 实景测试页不再
有自己的一套音源开关：它和通话用同一个设置（设置 → 语音 → 通话收音），
auto 的判断也只做一遍（`speech/MicSource.kt`）。这解决了原来那个更要紧的问题：
两条路径可能收的不是同一路声音，分数不可比。见 §八。

---

## 三、已排除的方向（别再走一遍）

按时间顺序，这些都**不是**根因：

| 猜的 | 实际 |
|---|---|
| 内存不足 | 47GB 机器，可用 28GB |
| JDK 21 冲突 | 该修但不是原因 |
| Gradle daemon 崩溃 | 是结果不是原因 |
| APK 副本堆积 | 清完照样卡 |
| 代理不可达 | curl 200、0.37s 正常 |
| 声纹阈值设太高 | 阈值是在错数据上调的 |
| 起音瞬态 | 存在，但被 2.1 的 bug 掩盖了 |
| 采集读到填 0 的空缓冲 | 部分对——确有零值，但主因是 2.1 |
| READ_BLOCKING 能修好 | **反了**——改完动态范围掉到 1/40 |

**最省时间的方法：拉录音看「唯一值个数 + 峰值」，再看 20ms 帧的
能量分布。** 这轮所有真结论都是这么得出来的，靠读代码猜的全错了。

```bash
adb -s <serial> pull /sdcard/Android/data/io.github.ccch1mneyyy.dsh_app/files/voiceprint-clips ./
# 然后逐帧算 RMS(dB)，并用 Counter(samples) 看取值分布
```

---

## 四、未解决 / 待办

### ~~P0：修 2.1 的引用 bug，然后重新验证~~ **已完成**

> 2026-11-21 核实：`VoiceprintRecorder` 里已经是 `chunks.add(buffer.copyOf(n))`
> （提交 `9d84ad42`），下面这段留作记录。验证标准仍然有用——重录声纹后照它看。

代码在 stash 里，但**不要直接 pop**——里面同时带着 `READ_BLOCKING` 和
`min*8` 这两个已被证伪的改动。只挑 `buffer.copyOf(kept)` 那一处：

```bash
git stash show -p stash@{0} -- '*VoiceprintRecorder.kt'
```

改完后的验证标准（不用装 APK，先看离线）：

```
录音唯一值 > 1500、峰值 > 1200   → 采集正常
三段自检 worst > 0.6             → 同一个人一致性正常
```

### ~~P1：重做 CMVN~~ **已完成**

> 见 2.3 的「已过期」框：`a690e4b4` 已经把「算完均值就返回」改成逐维减均值，
> `applyMean` 也接回了推理路径。本项不用再做。

### P2：重建评估集

回滚把 `VoiceprintEval` 一起带走了（在 `archive-before-rollback-20261121`
里）。这个工具本身是对的，值得恢复，但要先解决一个问题：

**现有 37 段模板来自同一次录入会话的连续切片**，内容/音源/位置全一样，
留一法互比 0.998——这个数不能当准确率看。

需要采集：

| 类型 | 用途 | 建议份数 |
|---|---|---|
| 本人多场景录音 | 测同人一致性 | 至少 5 段，不同时间/距离 |
| 旁人录音 | 测拒识能力 | 至少 3 人 × 2 段 |
| TTS 回声片段 | 定 playingBoost | 若干，需人工标注 |

### P3：Xperia 上的 AEC 实测

「回声消除诊断」→「量一遍」。目前只有 Pixel 的数据，而 Pixel 的通话
音源本身是废的，参考价值有限。

### P4：真机上核对音源统一（§八）

「回声消除诊断」→「音源」两栏应该给出同一路音源，以及量到的 VC/VR 峰值。
两栏不一致，说明设置没送到原生或被别的路径覆盖了。

---

## 五、环境坑

### 编译卡死

`flutter build` 会吃掉 Gradle 的真实错误。判断是否真在编译**看有没有
java 子进程在烧 CPU**，别只看进程活着。

- `HTTP(S)_PROXY=127.0.0.1:52762` 会切断 Kotlin daemon 的本地 socket
- `app/android/gradle.properties` 里已有 `kotlin.compiler.execution.strategy=daemon`
- 打包脚本里设 `NO_PROXY=localhost,127.0.0.1,::1`

**本轮新踩到两个**：

1. `:app:cleanMergeArm64ReleaseAssets` 报 `Unable to delete file`——
   上次打包进程残留的文件锁，删掉 `app/build/app/intermediates/assets` 再跑
2. `compileFlutterBuildArm64Release` 卡 17 分钟被系统杀掉，原因未明
   （Flutter AOT 阶段）。遇到时先 `flutter clean`

### JDK

**必须用 `tools/jdk17`。** 机器上有 JDK 21，AGP 在 21 上会无声卡死。

### git lock 残留

中断 `git reset --hard` 会留下 `.git/index.lock`。确认没有 git 进程后
直接 `rm -f .git/index.lock`。

### Xperia 锁屏

有密码，adb 解不开（`input keyevent 82` 无效）。电量低会限制后台，
`dumpsys battery | grep level` 查。

---

## 六、关键文件

```
app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/
├── nativemedia/
│   ├── KaldiFbank.kt        ← CMN/CMVN 在这
│   ├── CampplusEmbedder.kt  ← fbank → 模型 → L2
│   ├── SpeakerGate.kt       ← 判定核心
│   └── Thresholds.kt        ← 阈值曲线（数据修好后才该动）
└── speech/
    ├── VoiceprintRecorder.kt ← 声纹采集 / probeSources（音源实测在这）
    ├── AecSupport.kt         ← AEC 四层诊断
    ├── MicSource.kt          ← **音源选择**：通话和实景测试共用（§八）
    ├── SpeakerScreenTest.kt  ← 实景测试（音源由 MicSource 传入）
    └── Voiceprint.kt         ← 运行时静默参数

app/lib/ui/settings/
├── voiceprint_enroll_page.dart  ← 录入页（_finish 自检在这）
├── screen_test_page.dart        ← 实景测试页（音源跟随「通话收音」，只显示结果）
└── aec_diagnostics_page.dart    ← AEC 诊断页 + 音源探测结果
```

---

## 七、给接手的人一句话

**这一轮反复走了「读代码猜原因 → 改 → 打包 → 让用户对着手机说话」的
弯路，最后证明真结论全部来自原始数据。**

下一步的正确顺序是：先修 P0，然后用离线评估把「录音质量」这个变量钉死，
再去碰任何阈值、任何模型参数。**在数据没修好之前，所有关于阈值和归一化
的结论都不可信。**

---

## 八、采集音源统一（2026-11-21）

### 原来错在哪

两条路径各挑各的音源：

| 路径 | 音源从哪来 | auto 时怎么定 |
|---|---|---|
| 通话 | 设置 →「通话收音」（auto/communication/recognition） | `SpeechPlugin.autoPickRecognition()` 比 VC/VR 峰值，差 > 20 dB 换 VR |
| 实景测试 | 页面自己的 comm/recog/mic 三段开关 | 没有 auto，默认钉死 `VOICE_COMMUNICATION` |

同一台机器上可能一个收 VC、一个收 VR（Sony 上两路差 53 dB），**分数不可比**，
"实景测试打断成功但通话打断不了"这类现象也就没法归因。

### 现在

`speech/MicSource.kt` 一处决定，两条路径共用：

- 入口仍是**一个**设置：`callStart` 的 `micSource` 和 `screenTestStart` 的
  `source` 都把它送进来（默认 `auto`）。
- 判据没变：`MicSource.SWAP_DB = 20.0`（识别比通话高 20 dB 以上才换），
  只是从 `SpeechPlugin` 挪进 `MicSource`；**`Thresholds.kt` 没碰**。
- 每次决定留一条 `Pick`：量到的 VC / VR / MIC 峰值、差值、选了哪一路、为什么。
  `lastCall` 和 `lastScreenTest` 分开存，诊断页并排看。
- MethodChannel 只做**增量**：新增 `micSourceReport`、`micSourceProbe`；
  `screenTestWindow` 多 `source` / `sourceRequested` 两个键。旧的 `source`
  取值（`comm` / `recog` / `mic` 和缺省）仍然认，旧版 Dart 行为不变。

### 已知代价（本轮没动）

- 通话路径的 auto 探测仍在**主线程同步**做（三条音源各 1.5 秒，约 4.5 秒）。
  这是改动前就有的，没顺手改时序——要改的话得让 `callStart` 异步回答，
  牵到挂断竞态，另开一单。
- `screenTestSaved` 从不清零，跨轮累加到 6 之后就不再存 wav（第二次测试起
  没有可回听的录音）。与本轮无关，记在这里。

### 真机上要看的两个数

1. **实景测试与通话在同一音源下的峰值差**：诊断页「音源」两栏的 `chosen`
   必须是同一路；然后各跑一次，两次报的 VC/VR 峰值应当接近（同机同声场下
   差值远小于 20 dB 的门槛）。差得多，说明 auto 在两条路径上做了不同判断。
2. **诊断页能看到的探测结果**：「通话最近一次」和「实景测试最近一次」两行
   各自带"实测峰值：通话 −74.1 / 识别 −20.8 dBFS，差 53.0 dB"和一句结论
   （"换识别——通话那一路把人声吃掉了"）。手动「量一遍音源」还会额外给出
   原始麦克风那一路。
