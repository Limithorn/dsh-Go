# 本地离线 TTS（Kokoro）handoff — MIC-95

> 2026-11-28。把 `fix/mic-source-unify` 上的本地离线 TTS 按模块化规范移植到 self-dev 线的交接记录。
> 规范依据 `docs/design/fork-modularity-standard.md`；接触面登记见 `docs/design/fork-seams.md` §1 行 01。
> fix 线参考提交（`git log --follow app/lib/speech/local_tts.dart`）：26c880c8f → 90f7f5470 →
> 5109e7dc9 → 88eddd425 → 40e93af33 / 1d2459d33 → cafb4b5a7。

## 1. 已确认（带证据）

- **模型加载与合成留在主 isolate；解包单独 `Isolate.run`。** 后台 isolate 里 eSpeak 设嗓音会 abort 整个
  进程（`Failed to set eSpeak-ng voice`，`/data/anr` 记录 DartWorker SIGABRT，fix 线 40e93af33/1d2459d33）；
  而主 isolate 直加载 311MB 又实测 ANR（`Waited 5005ms for MotionEvent`，fix 线 90f7f5470）。两件事不矛盾：
  下载/校验后的解包是纯 Dart archive 解码，进 `Isolate.run` 离开 UI 线程；sherpa 模型加载与合成则回到
  sherpa ASR 已在的主 isolate。issue 描述里的「dsh-tts 专用 isolate」是中间方案，最终代码以本条为准。
- **模型选型**：kokoro-multi-lang-v1_0 **未量化** `model.onnx`（350MB tar.bz2，URL/SHA-256/大小三件钉死，
  见 `LocalTtsPack`）；int8 版省 240MB 但金属感明显。中文合成必须双 lexicon（`lexicon-us-en.txt` +
  `lexicon-zh.txt`）+ `lang: 'zh'`，否则中文走英文音素。音色 sid：45–48 中文女声（默认 **48 = zf_xiaoyi**）、
  49–52 中文男声；3/6 是 af_heart/af_nicole（曾经英文音色念中文的根源）。
- **下载断点续传 + 校验**：`.part` 文件按 `range` 头续传；比 pack 还长 → 判非己物重下；SHA-256 不符删档并抛
  `LocalTtsError('checksum')`——下载失败给可执行错误，不静默。页面把失败原因按行内短句展示
  （`_shortError`，110 字截断），不依赖会被错过的 snackbar。
- **生僻字符过滤**（fix 线 5109e7dc9）：送模型前只留字母/数字/空格/中文逗号句号，其余字符（含英文句号
  逗号）一律改中文逗号再折叠——eSpeak 念不出的字符曾让合成直接 abort。`app/test/speech/local_tts_test.dart`
  把这条钉进测试（输出永远落在可念字符集内）。
- **音色持久化**（cafb4b5a7 的教训）：`localVoice` 随 `plain()/fromPlain()` 存档；旧存档没有该键 → 落回默认
  48。**切换入口仍未做**：fix 线试过 SettingsTile + SimpleDialog，行显示出来了但点击不命中（该行在无障碍树里
  不存在），查不清先拿掉，免得留一个点不动的入口。接 UI 时直接读写
  `CompanionVoiceSettings.localVoice` 即可，存储两端都已就绪（测试钉了往返）。
- fix 线一处注释笔误在移植时修正：settings 字段注释写「6 is zf_xiaoyi」——6 是 af_nicole，48 才是 zf_xiaoyi
  （`local_tts.dart` 自己的注释是对的）。

## 2. 已排除

- **合成搬后台 isolate**：见上，eSpeak abort，不可行；不要再试。
- **int8 量化模型**：省 240MB，听感金属感明显，不采用。
- **removeLocalTts() 的 UI 与 `companionVoiceLocalRemove` l10n 键**：fix 线同样没接线（键存在于 arb、无任何
  Dart 引用）。本次**未移植该键**；`removeLocalTts()` 函数随 A 区文件照搬保留，后续接 UI 时连键一起补。
- **pubspec 改动**：不需要——上游 main 已钉 `sherpa_onnx 1.13.4`（Kokoro OfflineTts 在该版 API 内），
  `archive/crypto/http/path_provider` 也都是既有依赖（fix 线 pubspec 的 +4 行是唤醒词的 lpinyin 与
  assets/wake/，属 MIC-100 域，未随本次移植）。

## 3. 未解决 / 决策点

- **D-TTS-1（真机四项，全部未跑，如实标注）**：预热后离线首句延迟；锁屏朗读；音色切换持久化（当前无切换
  入口，真机验证「改 localVoice 存档 → 下一句即用新 sid」）；中文音色不发英文音素。本机为 macOS、无
  Android 真机；按仓库 AGENTS「桌面结果不能替代真机」。
- **D-TTS-2（与 02 Edge 共用挂点）**：`companion_voice_source.dart` 的枚举行、`configured`、fetch 分支与
  MIC-96 共用同一文件相邻行——Edge 落地时按 fork-seams §1 行 01/02 逐行核对，别互相覆盖。
- **D-TTS-3**：`CompanionVoicePage` 打开即探本地安装态（initState `_refreshLocal`）；ohos 无此音源入口，
  与其余非系统音源同条件屏蔽（`if (!ohos)`）。

## 4. 移植面与验证（2026-11-28，本机 macOS）

- **A 区**：`app/lib/speech/local_tts.dart`（+297 照搬；LICENSE 注释补齐资产四件套——Apache-2.0，
  随 sherpa-onnx releases 发布）。
- **B 区（全部打 `fork(tts)` 标，登记 fork-seams §1 行 01）**：`companion_voice_source.dart`（枚举 +1 值、
  `localVoice` 字段四件套、`configured`、fetch `_local` 分支、`warmLocalTts()`/`_localTts` 缓存）；
  `app.dart`（import ×2 + initState 预热块：两处设置任一选 local 才预热）；`companion_voice_page.dart`
  （import + 安装态探测 + 音源列表 1 行 + 下载/进度/失败分区）；`voice_settings_page.dart`
  （`speechVoiceLabel` 补 local 臂——穷举 switch，枚举加值必改）；l10n `parts/companion_{zh,en}.arb`
  各 +6 键（`companionVoiceLocal*`；ARB 是 JSON 不能内联打标，以登记表代之）。
- **测试**：新增 `app/test/speech/local_tts_test.dart`（speakableForTts 过滤/折叠、wavOf 头与钳制、
  `LocalTtsPack` 四件套断言）；`companion_voice_source_test.dart` +2（localVoice 存档往返 + 旧存档落默认、
  local 失败给可读错误）；`companion_voice_test.dart` android 音源清单 +`local`（ohos 清单不变）。
- **实际执行与结果**：
  - `flutter pub get`：无改动（pubspec 未动）。
  - `python3 tool/l10n_merge.py` + `--check`：✓ 79 parts / 8997 键（改前 8991）。
  - `flutter analyze`（app/）：**No issues found**（47s）。
  - `flutter test test/speech test/companion/companion_voice_source_test.dart test/companion/companion_voice_test.dart
    test/settings/voice_settings_test.dart test/l10n test/settings/appearance_page_test.dart
    test/settings/palette_width_test.dart test/launch/launch_root_test.dart`（改动面前后同集对照）：
    改前 **+195/−5** → 改后 **+204/−5**，失败集合逐条一致（5 条均为本机既有 appearance golden 渲染差异，
    属 MIC-94 报告过的本机基线，非本次引入）；新增 9 个用例全绿。
  - Kotlin 单测、真机：本次无原生改动，未涉及；真机项见 D-TTS-1。
