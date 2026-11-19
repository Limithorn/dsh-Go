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
export JAVA_HOME="${JAVA_HOME:-C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/jdk17}"
export ANDROID_HOME="${ANDROID_HOME:-C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/android-sdk}"
FLUTTER="${FLUTTER:-C:/Users/FELiCiTas/Desktop/AGENT/HANAKO/tools/flutter/flutter/bin/flutter.bat}"

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

echo "→ ${NAME}"
"$FLUTTER" "${ARGS[@]}"

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
