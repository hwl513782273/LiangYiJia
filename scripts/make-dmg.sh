#!/bin/bash
# 把 build/晾衣架.app 打成 dmg，产物放 dist/。
# 用法：scripts/make-dmg.sh [版本号]     默认 1.0.0
#
# 命名沿用以前的规矩：12-LiangYiJia-<版本>-universal.dmg
# 12 = 最低支持的 macOS（Monterey），universal = arm64 + x86_64 粘在一起。

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/晾衣架.app"
VERSION="${1:-1.1.0}"
MIN_MACOS="12"
OUT_DIR="dist"
NAME="${MIN_MACOS}-LiangYiJia-${VERSION}-universal.dmg"

if [ ! -d "$APP" ]; then
  echo "找不到 ${APP}，先跑：scripts/build-app.sh release" >&2
  exit 1
fi

# 打之前先确认真的是 universal：只编了一个架构的包拿到别的机器上跑不起来。
ARCHS=$(lipo -archs "$APP/Contents/MacOS/晾衣架")
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "警告：当前只有 [${ARCHS}]，不是 universal。要兼容 Intel 请用 scripts/build-app.sh release（默认两个架构）" >&2 ;;
esac

mkdir -p "$OUT_DIR"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# 拖拽安装的经典样子：左边 App，右边 Applications 快捷方式
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> 打包 ${OUT_DIR}/${NAME}（架构：${ARCHS}）"
rm -f "$OUT_DIR/$NAME"
hdiutil create -volname "晾衣架" -srcfolder "$STAGE" -ov -format UDZO -quiet "$OUT_DIR/$NAME"

echo "==> 完成"
ls -lh "${OUT_DIR}/${NAME}"
