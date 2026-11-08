#!/bin/bash
# 构建「晾衣架.app」（Tendedero 的本地改版：加了悬停放大预览）
# 用法：scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/晾衣架.app"
VERSION="1.0.0"
# 最低支持的 macOS。12 = Monterey：既是 Intel Mac 还能装的系统，也覆盖 Apple Silicon 全部机型。
# 改这个要同时改 Package.swift 的 platforms 与 Info.plist 的 LSMinimumSystemVersion。
MIN_MACOS="12.0"
# SwiftPM 的 target 名保持 Tendedero：改它要动 Sources 目录名，牵连太大，没必要
PRODUCT_NAME="Tendedero"
# 装进 bundle 后的可执行文件名 = 系统认的 App 名。
# 这里必须叫「晾衣架」：macOS 的「后台项目已添加」通知、登录项列表、
# 活动监视器里的进程名，全都取这个文件名，写 Tendedero 就会显示成别人的名字。
BIN_NAME="晾衣架"

# 默认出 universal（arm64 + x86_64 粘成一个包），Intel Mac 与 Apple Silicon 都能装。
# 只想要本机架构、图快一半时间：ARCHS=arm64 scripts/build-app.sh release
ARCHS="${ARCHS:-arm64 x86_64}"

echo "==> 编译（架构：${ARCHS}，最低系统：${MIN_MACOS}）"
# 变量紧挨中文全角标点时必须写 ${VAR}：bash 3.2 在非 UTF-8 locale 下会把汉字的
# 高位字节算进变量名，报出 "ARCHS<乱码>: unbound variable"
# --disable-sandbox：SwiftPM 评估 Package.swift 时会调用 sandbox-exec，
# 在我们这个受限环境里会报 Operation not permitted，关掉即可
SLICES=()
for arch in $ARCHS; do
  echo "    - $arch"
  swift build -c "$CONFIG" --triple "${arch}-apple-macosx${MIN_MACOS}" --disable-sandbox >&2
  SLICES+=("$(swift build -c "$CONFIG" --triple "${arch}-apple-macosx${MIN_MACOS}" --disable-sandbox --show-bin-path)/$PRODUCT_NAME")
done

# 单个架构直接用；两个架构用 lipo 粘成一个 universal 二进制
if [ ${#SLICES[@]} -eq 1 ]; then
  BIN="${SLICES[0]}"
else
  mkdir -p build
  BIN="build/$PRODUCT_NAME-universal"
  lipo -create "${SLICES[@]}" -output "$BIN"
  echo "    lipo 合并：$(lipo -archs "$BIN")"
fi

echo "==> 组装 app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"

echo "==> 生成图标（自绘，不使用原作者的图标）"
WORK="$(mktemp -d)"
swift scripts/make-icon.swift "$WORK/icon.png" >&2
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

echo "==> 拷贝翻译"
LANGUAGES=""
for dir in Sources/Tendedero/Resources/*.lproj; do
  cp -R "$dir" "$APP/Contents/Resources/"
  LANGUAGES="$LANGUAGES<string>$(basename "$dir" .lproj)</string>"
done

echo "==> 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>晾衣架</string>
  <key>CFBundleDisplayName</key><string>晾衣架</string>
  <key>CFBundleIdentifier</key><string>com.local.liangyijia</string>
  <key>CFBundleExecutable</key><string>${BIN_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LANGUAGES}</array>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>晾衣架需要查看截图保存的位置，才能把新截图挂到线上。</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>晾衣架需要查看你选择的文件夹，才能把里面的新图片挂到线上。</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>晾衣架需要查看你选择的文件夹，才能把里面的新图片挂到线上。</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> 完成：$APP"
