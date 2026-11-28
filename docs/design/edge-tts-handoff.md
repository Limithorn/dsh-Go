# Edge 云端 TTS handoff — MIC-96

> 2026-11-28。把 `fix/mic-source-unify` 上的 Edge 云端 TTS 按模块化规范移植到 self-dev 线的交接记录。
> 规范依据 `docs/design/fork-modularity-standard.md`；接触面登记见 `docs/design/fork-seams.md` §1 行 02。
> fix 线参考提交（`git log --follow app/lib/speech/edge_tts.dart`）：1daa4a708 → 88eddd425 →
> edd2c2ac3 → 1f31835c7。

## 1. 已确认（带证据）

- **裸 socket 是唯一可行路**：`dart:io` 的 HttpClient 把 `Connection`/`Upgrade` 当保护头静默丢弃，
  upgrade 一律 403 "Invalid Request"（fix 线 1daa4a708 记录过整段 403 时期）。A 区文件按浏览器扩展
  发出的字节原样握手，不走 WebSocket 库。
- **协议全部钉在 Edge 扩展行为上**：`TrustedClientToken` 固定值、`Origin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold`、
  `Sec-MS-GEC` 签名（SHA-256 + cs64 校验和，算法钉 msedge-tts 2.1.1）、SSML 的
  `audio-24khz-48kbitrate-mono-mp3`。微软未公开任何一篇文档；哪天关掉即整路失效——失败只影响
  edge 一档（`_edge` 早退分支），其余声音源零牵连。
- **签名按 300 秒取整 + 时钟偏移修正**：手机时钟偏差几分钟（fix 线实测有一台快 30 分钟）时，
  错误分钟的签名被拒；所以每次运行读一次服务器 `Date` 头算偏移（`_serverOffset`）。
  单测用可注入时钟把「同桶同值、跨 300 秒变值、偏移等效后移」钉死。
- **音量 +40% 听感补偿**（fix 线 edd2c2ac3）：服务默认出声偏小，外放/听筒都显轻；`volume='+40%'`
  是 `edgeSpeak` 的默认参数，抬到听得清又不到削波。
- **错误出口可执行、不静默**：`EdgeTtsError` → `CompanionVoiceError('edge <原因>')` →
  `lastError` 行内展示（connect 失败 / handshake 非 101 / turn.error / timeout / empty reply 各有
  短句），用户看到原因即可去音源页换回 system/DeepSeek/本地；不重试、不风暴。
- **联网面**：只连 `speech.platform.bing.com:443`（合成 websocket + 读 Date 头各一次），
  无其他域名、无遥测。
- **音色表**：8 个（zh-CN ×5 含默认 `zh-CN-XiaoyiNeural`、zh-TW ×1、en-US ×2），
  `edgeVoice` 随存档往返（`plain()/fromPlain()`），旧存档无该键落回默认——与 local 的
  `localVoice` 同一模式。

## 2. 已排除

- **`dart:io` WebSocket / HttpClient**：见上，403，不要再试。
- **app.dart 预热**：Edge 无本地模型可载，不需要（与 local 不同）；`_serverOffset` 在首次合成时
  懒取即可。A 区在 app.dart 零挂点。
- **重试与兜底链**：不加。失败如实上抛是本模块的设计前提（协议随时可能整段失效，静默重试只会
  把「服务没了」伪装成「卡了」）。
- **边合成边播**：`edgeSpeak` 网络层流式收包（`BytesBuilder` 攒帧），但返回完整 mp3 后才交播放；
  fix 线就是这个形态，播放侧（companion_voice.dart）零改动。真机的「流式不卡顿」验收指的也是
  这个收包形态，见 D-EDGE-1。
- **Sec-MS-GEC 的 golden 向量**：本机未取 msedge-tts 2.1.1 的参照向量，单测钉的是形状/确定性/
  300 秒桶/偏移等效四条结构性质，不钉具体字节值。要钉死字节级回归，需拿参照客户端跑一个固定
  时间戳的向量补进 `edge_tts_test.dart`（缝已留好：`edgeSecMsGecAt`）。

## 3. 未解决 / 决策点

- **D-EDGE-1（真机四项，全部未跑，如实标注）**：外放一段长句确认流式收包不卡顿；音量 +40%
  听感确认；切换音色即生效（改 `edgeVoice` 存档 → 下一句即用新音色）；断网时错误提示可执行
  （行内 `edge connect …` 短句 + 引导换音源）。本机为 macOS、无 Android 真机；按仓库 AGENTS
  「桌面结果不能替代真机」。
- **D-EDGE-2（协议钉死风险）**：微软改动 TrustedClientToken 校验 / Sec-MS-GEC 版本（现在是
  `2-143.0.3650.96`）即整路 403。处置约定：不动其他声音源，音源页把 Edge 行的失败原因展示
  出来即可（现有 UI 已满足）；若要删本模块，A 区一个文件 + B 区挂点全带 `fork(tts)` 标，按
  fork-seams 行 02 摘除。
- **D-EDGE-3（与 01 共用挂点的核对结果）**：`companion_voice_source.dart` 的枚举行、`configured`、
  fetch 分支与 local 相邻行已逐行核对——edge 的每一处都插在 local 的对应行旁、不动 local 任何
  一行（fix 线同文件 diff 佐证）；`companion_voice_test.dart` 的 android 音源清单两行都更新、
  ohos 清单不变。

## 4. 移植面与验证（2026-11-28，本机 macOS）

- **A 区**：`app/lib/speech/edge_tts.dart`（fix 线 416 行照搬；两处测试性改动——`_secMsGec` 加可
  注入时钟参数、文件尾追加四个只读离线缝 `edgeHeadEndAt/edgeParseFrame/edgeAudioOf/edgeSecMsGecAt`，
  行为零变化）。
- **B 区（全部打 `fork(tts)` 标，登记 fork-seams §1 行 02）**：`companion_voice_source.dart`（枚举 +1
  值、`edgeVoice` 四件套、`configured` +1 臂、fetch `_edge` 早退、switch 认全枚举）；
  `companion_voice_page.dart`（import + 音源列表 1 行 + 音色选择分区）；
  `voice_settings_page.dart`（`speechVoiceLabel` 补 1 臂——穷举 switch，枚举加值必改）；
  l10n `parts/companion_{zh,en}.arb` 各 +3 键（`companionVoiceEdge*`）。
- **测试**：新增 `app/test/speech/edge_tts_test.dart`（14 例：帧读取 5——opcode/掩码/16·64 位
  长度/半帧 null/连帧顺序；音频帧 2；响应头 2；签名 3；空文本拒绝 1；音色表 1）；
  `companion_voice_source_test.dart` +1（edgeVoice 存档往返 + 旧存档落默认）；
  `companion_voice_test.dart` android 音源清单 +`edge`（ohos 不变）。
- **实际执行与结果**：
  - `flutter pub get`：无改动（pubspec 未动；`crypto` 为既有依赖）。
  - `python3 tool/l10n_merge.py` + `--check`：✓ 79 parts / 9000 键（改前 8997）。
  - `flutter analyze`（app/）：**No issues found**（28s）。
  - `flutter test`（与 MIC-95 同集前后对照）：改前 **+204/−5** → 改后 **+219/−5**，失败集合逐条
    一致（5 条均为本机既有 appearance golden 渲染差异，属 MIC-94 报告过的本机基线，非本次引入）；
    新增 15 个用例全绿。
  - Kotlin 单测、真机：本次无原生改动，未涉及；真机项见 D-EDGE-1。
