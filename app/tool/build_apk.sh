#!/usr/bin/env bash
# 打一个"看得出是哪一个"的 APK。
#
# 默认 flutter build 出来的叫 app-arm64-release.apk，每回都一样——装了三版
# 之后分不清手机上跑的是哪一版。这个脚本把版本号、提交、时间、是否带未提交
# 改动都编码进文件名，并在系统里能对上的地方留一份。
#
# 用法：
#   tool/build_apk.sh              # release
#   tool/build_apk.sh --debug      # debug
#   tool/build_apk.sh --install    # 打完顺手装到连着的设备上
#
# 名字长这样：
#   dsh-1.2.0-abcdef1-20261119-0920-release.apk
#   └版──┘ └提交─┘ └──时间──┘ └模式┘
# 有未提交改动时，提交那段后面加 -dirty。

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="release"
DO_INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --debug) MODE="debug" ;;
    --install) DO_INSTALL=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# ---- 版本与提交 ----------------------------------------------------------
VERSION=$(grep -m1 '^version:' pubspec.yaml | sed 's/^version: *//' | tr -d ' ')
# 只留 1.2.0 那段，把 +1 的 build 号单独拿出来（文件名里太挤）。
VERSION_NAME=${VERSION%%+*}
BUILD=$(git rev-parse --short HEAD)
if ! git diff --quiet HEAD -- . 2>/dev/null; then
  BUILD="${BUILD}-dirty"
fi
STAMP=$(date +%Y%m%d-%H%M)

NAME="dsh-${VERSION_NAME}-${BUILD}-${STAMP}-${MODE}"

# ---- 编译 ----------------------------------------------------------------
# 固定用仓库自带的 JDK 17。
#
# 不能写 ${JAVA_HOME:-...}：机器上装了 JDK 21 时那个值会被继承过去，而
# AGP 的这个版本在 21 上会卡住不报错（实测打了二十分钟没有任何输出）。
JDK17="C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/jdk17"
if [ -d "$JDK17" ]; then
  export JAVA_HOME="$JDK17"
fi
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME="${ANDROID_HOME:-C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/android-sdk}"

# 本地回环不要走代理。
#
# 这台机器上 HTTP(S)_PROXY 指向 127.0.0.1:52762。Gradle/Kotlin 编译进程之间
# 走本地 socket 通信，被代理插一手就会 Connection reset——表现为编译卡死
# 十几分钟然后把任务挂住。编译本身不需要外网。
export NO_PROXY="localhost,127.0.0.1,::1"
export no_proxy="$NO_PROXY"

FLUTTER="${FLUTTER:-C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/flutter/flutter/bin/flutter.bat}"

echo "  java: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

ARGS=(build apk --flavor arm64 --target-platform android-arm64)
if [ "$MODE" = "release" ]; then
  ARGS+=(--release)
else
  ARGS+=(--debug)
fi

# 把文件名这一串传进 App，设置页「诊断」里能直接看到跑的是哪一版。
# --dart-define 是编进包里的，运行时不依赖外部文件。
ARGS+=(--dart-define=DSH_BUILD_NAME="${NAME}")
ARGS+=(--dart-define=DSH_BUILD_COMMIT="${BUILD}")
ARGS+=(--dart-define=DSH_BUILD_TIME="${STAMP}")

LOG="build-apk.log"

echo "→ ${NAME}"

# ── 先单独跑一遍 AOT ──────────────────────────────────────────────
#
# 为什么：`flutter build apk` 里，Dart 的 AOT（android_aot_bundle_release_*）
# 和 Gradle 的其它任务并行跑时会**卡死**——进程还在，CPU 不涨，没有任何
# 输出，10 分钟、20 分钟都不动，只能手动杀掉。
#
# 证据：同一个任务单独跑（下面这段）156 秒就完成，一次没卡过。所以不是
# AOT 本身的问题，是并行时的资源竞争。
#
# 先在这里把它做掉，flutter build 时这一任务就 up-to-date、直接跳过，
# 并行那一步也就不存在了。
#
# 注意不要用 `rm -rf build` 来"解决"卡死：清空之后 AOT 必须从头做，
# 反而更容易踩到并行阶段。留着上次的中间产物，只重跑这一任务最快。
if [ "$MODE" = "release" ]; then
  DART="${FLUTTER%/flutter.bat}"
  DART_SDK="$DART/cache/dart-sdk/bin/dart.exe"
  TOOLS="$DART/cache/flutter_tools.snapshot"
  PKGS="$DART/packages/flutter_tools/.dart_tool/package_config.json"
  if [ -x "$DART_SDK" ]; then
    echo "  AOT 预跑（避免并行卡死）..."
    # 超时保护：这一步正常 2~3 分钟出 app.so，但如果上一次跑完 app.so
    # 已经是最新的，它会在**收尾阶段空转**——进程活着、CPU 不涨、不再写
    # 日志，看起来跟卡死一模一样，实测能挂 10 分钟以上。产物其实早就好了。
    #
    # 所以给 6 分钟上限：超时就算了，产物在就用，不在让 flutter build 自己做。
    # 判据看 app.so 有没有，不看退出码——被超时杀掉时退出码不可靠。
    AOT_SO="build/app/intermediates/flutter/arm64Release/arm64-v8a/app.so"
    BEFORE=$(stat -c %Y "$AOT_SO" 2>/dev/null || echo 0)
    if command -v timeout >/dev/null 2>&1; then
      timeout 360 "$DART_SDK" --packages="$PKGS" "$TOOLS" assemble --no-version-check \
        -dTargetFile=lib/main.dart -dTargetPlatform=android -dBuildMode=release \
        -dFlavor=arm64 -dAndroidArchs=android-arm64 -dMinSdkVersion=26 \
        --output build/app/intermediates/flutter/arm64Release \
        android_aot_bundle_release_android-arm64 >> "$LOG" 2>&1
      AOT_STATUS=$?
    else
      AOT_STATUS=0
    fi
    AFTER=$(stat -c %Y "$AOT_SO" 2>/dev/null || echo 0)
    if [ "$AFTER" -gt "$BEFORE" ]; then
      echo "  AOT 产物已更新"
    elif [ "$AOT_STATUS" = "124" ]; then
      echo "  ⚠ AOT 预跑超时（产物可能已经是新的，继续）"
    elif [ $AOT_STATUS -ne 0 ]; then
      echo "  ⚠ AOT 预跑失败（$AOT_STATUS），交给 flutter build 重试"
    fi
  fi
fi

# 日志落到文件里：管道收给 grep 的话，卡在哪一步完全看不见。
# 这台机器上完整编译要 20 分钟到一个小时，看 tail -f 比盯着空屏强。
"$FLUTTER" "${ARGS[@]}" > "$LOG" 2>&1
STATUS=$?
if [ $STATUS -ne 0 ]; then
  echo "✗ 编译失败（$STATUS），最后几行：" >&2
  tail -20 "$LOG" >&2
  exit $STATUS
fi

SRC="build/app/outputs/flutter-apk/app-arm64-${MODE}.apk"
OUT="build/app/outputs/flutter-apk/${NAME}.apk"
if [ ! -f "$SRC" ]; then
  echo "expected $SRC, not found" >&2
  exit 1
fi
cp "$SRC" "$OUT"
echo "✓ ${OUT}"

# ---- 安装 ----------------------------------------------------------------
if [ "$DO_INSTALL" = "1" ]; then
  ADB="${ADB:-C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/android-sdk/platform-tools/adb.exe}"
  MSYS_NO_PATHCONV=1 "$ADB" install -r "$OUT"
  echo "✓ installed ${NAME}"
fi

# 单独建一个 latest 的软链式副本，方便脚本一直用同一个路径。
cp "$OUT" "build/app/outputs/flutter-apk/dsh-latest.apk"
echo "✓ build/app/outputs/flutter-apk/dsh-latest.apk"
