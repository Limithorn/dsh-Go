# 语音页改版与声纹调试 · 交接

> 时间：2026-11-24
> 分支：`fix/mic-source-unify`
> 设备：Xperia（QV770CNME9），Android 13

---

## 一、这一轮做了什么

### 1. 把两个分支 rebase 到上游

`main` 落后上游 **402 个提交**，51 个本地提交需要重放。

**做法**：先 rebase `main`，成功后再把 `fix/mic-source-unify` 跟上去。

**过程中的坑（重要）**：

`voice_call_page.dart` 在冲突时 HEAD 侧是 **CRLF**，原仓库是 **LF**。git 逐行匹配全失败，把一个 1900 行的文件标成整块冲突，实际每个提交只改了几行。

写了个三方合并脚本处理，自动过了 20 多轮。

**但脚本丢了东西**（跑测试才暴露）：

| 丢的 | 后果 |
|---|---|
| `AppPage.list` 的 `showLargeTitle` 转发 | 三个诊断页编译不过 |
| `app_info.dart` 的 `buildLabel` 块合并两遍 | 重复定义 |
| `SystemAsrCard` 整个类（65 行） | 测试找不到类 |
| `FakeAudio.startCall` 的 `micSource` 参数 | test/speech 编译失败 |
| `voice_call_page.dart` 缺两层右括号 | 语法错误 |

**教训**：rebase 跨 400 个提交时，每个提交都要重新解冲突，**丢改动的机会是 merge 的 51 倍**。上游不接受 PR 时这也是唯一选择，但必须逐项核对 + 跑测试验证。

### 2. 语音页新增两张卡

上游那五组（朗读 / 语音模式 / 语音模型 / 实景 / 通话）**一个字没动**，在末尾追加：

**通话增强**（公共底层，声纹关掉也生效）
- 麦克风音源（三档二级页）
- 麦克风增益（滑条 1~8× + 「量一下」）
- 插话灵敏度（五档胶囊）

**声纹**（总闸 + 模型 + 录入，随总闸置灰）
- 判定门槛（滑条 0.20~0.95，四档做刻度）
- 静默检测（三档，带 `VAD` 角标）
- 插话灵敏度（五档）
- 他人打断
- 我的声音（子页：录入 / 自测 / 实景）

### 3. 这一轮的四个 bug 修复

**a. 判定门槛滑条一定吸附到档位**

```dart
value: _acceptOf(call.voiceprintLevel),   // 永远从档位读
onCommit: (v) => setAccept(v),             // 只推给原生，不保存
```

松手后值没存，重建又读回档位。第一次修法放 `StateProvider`——**又错了**：

```dart
final vpAcceptProvider = StateProvider<double>((ref) {
  final level = ref.watch(callSettingsProvider).voiceprintLevel;  // ← watch
```

`ref.watch` 让 provider 跟着通话设置重建，**改任何别的选项都会把滑条冲回 0.4**。

最终方案：存进 `CallSettings.voiceprintAccept`（可空，`null` = 按档位算），持久化。`copyWith` 用 sentinel 区分「不改」和「设成 null」。

**b. 滑条 + 「按档位选」重复**：删掉后者，四档只做刻度标签。

**c. 录入页 5 行重复**：收成 2 组 2 行（录入 / 测试）。

**d. 实景测试说「没模板」**

```dart
ref.read(provider).value ?? const []   // 加载中时 value 是 null
```

模板在加密存储里，读取要时间。点得快就读到 null → 被当成空列表。
改成 `await ref.read(provider.future)`。

---

## 二、未解决的问题（**下一步从这里开始**）

### 核心问题：实景测试采集不到声音

**日志证据**（2026-11-24 02:21）：

```
probe: {VOICE_COMMUNICATION=-61.8, VOICE_RECOGNITION=-47.0, MIC=-39.3}
stop: chunks=151 samples=48320 peak=0.0060
SpeakerScreenTest: started source=VOICE_COMMUNICATION aec=true
SpeakerScreenTest: stopped        ← 14 秒，一个窗口都没判
```

**三个事实**：

1. 实景测试**跑起来了**（`started` 有日志）
2. **一个 `score=...` 都没打** → 1.5 秒的窗口一次都没凑满
3. **峰值 0.0060** → 正常说话应在 0.1~0.5，**低约 30 倍**

**已排除**：

- 麦克风权限 `granted=true`
- TTS 引擎已装（`com.google.android.tts`），系统语言 `zh-CN`
- 已试过改系统 `tts_default_locale`（原为 `en_US`）

**关键推断**：

`VOICE_COMMUNICATION` 比 `MIC` **低 22 dB（约 12 倍）**。我把默认音源从 `auto` 改成 `communication`，**在这台机器上可能是错的选择**。

---

## 三、已经加了但还没验证的诊断日志

`SpeakerScreenTest.kt` 加了三条日志（**已编译通过，但那一版 APK 打包被中断，没装上**）：

```
warm-up done: N samples (target 6400)   ← 麦克风到底给不给数据
beat: windows=N samples=N               ← 每 2 秒一次，证明采集在推进
warm read returned -3 after N samples   ← read 一直不返回正数时
```

**这三个能区分两种情况**：

| 日志表现 | 结论 |
|---|---|
| `warm-up done: 0 samples` | 麦克风根本没给数据 → 权限/设备问题 |
| `warm-up done: 6400 samples` 但没 `beat` | 给数据了但凑不满窗口 → 缓冲区逻辑问题 |
| 有 `beat` 但没 `score` | 窗口在凑，但 `judge` 没被调用 |
| 有 `score` 但 `kind=OTHER` | 声纹判定问题，不是采集问题 |

---

## 四、下一步建议（按优先级）

### 1. 先装带诊断日志的版本

```bash
cd app && bash tool/build_apk.sh
adb install -r build/app/outputs/flutter-apk/dsh-latest.apk
```

跑一次实景测试，抓日志：

```bash
adb logcat -d | grep -E "SpeakerScreenTest|Voiceprint"
```

### 2. 如果确认是音源问题（最可能）

- 把「麦克风音源」默认值改回 `auto`，或改成 `recognition`
- 我之前改 `communication` 的理由是「auto 要等 4.5 秒」，**但如果 auto 才能正常工作，那 4.5 秒是值得的**
- 或者：开机时异步探测（不阻塞主线程），用完就切

### 3. 增益上限可能不够

日志峰值 0.0060，要到 0.1 需要 **16 倍**，而滑条最大才 **8×**。
可能要把上限提到 32×，或者「量一下」自动算出正确倍数。

### 4. TTS 不出声还没定位

已加 8 秒看门狗（超时退回并提示），**但根因没查**。
待确认：App 里的音色是「系统」还是「DeepSeek 云端」——后者走网络，和语音包无关。

---

## 五、构建相关

### 打包慢

Gradle 单独 **402 秒**，全流程约 9 分钟。工程 254 MB APK，含 ONNX 模型等多套原生库。缓存已全开（`org.gradle.caching=true`）。

### AOT 预跑会空转

`tool/build_apk.sh` 的 AOT 预跑在产物已是最新时会**收尾空转 10 分钟**——进程活着、CPU 不涨、不写日志，看起来跟卡死一样。

**已加 6 分钟超时**，判据改成看 `app.so` 的 mtime 有没有变新（不看退出码，被 timeout 杀掉时不可靠）。

### 回收站会堆 1.9 GB

Gradle 每次构建清理中间产物，Windows 把它们送进回收站（不是脚本删的，脚本里没有删除命令）。可以放心清空。

---

## 六、测试与验证方式

### 测试字体

本机没有 Noto CJK，golden 测试会失败。用环境变量指：

```bash
export DSH_TEST_FONT_DIR="C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/temp/testfonts"
```

（该目录是把 `msyh.ttc` 复制成 `NotoSansCJK-Regular.ttc` 等三个名字）

**注意**：golden 测试失败与代码无关，**用 `git stash` 对照验证过，原代码同样失败**。

### 当前测试状态

- `flutter analyze lib test`：干净
- `test/speech` + `test/ui`：**298 例全绿**

---

## 七、分支与备份

```
backup/main-before-rebase        rebase 前的 main
backup/fix-before-rebase         rebase 前的 fix
```

确认无误后可删除。

**当前状态**：`fix/mic-source-unify`，落后上游 **0**（已追平），领先 **76** 个提交。
