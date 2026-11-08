#!/bin/bash
# 构建「晾衣架.app」（Tendedero 的本地改版：加了悬停放大预览）
# 用法：scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/晾衣架.app"
VERSION="1.0.0"
# 二进制沿用 Tendedero 这个名字：SwiftPM 的 target 名改了会牵动所有文件，没必要
BIN_NAME="Tendedero"

echo "==> 编译（只编 arm64：这台机器是 Apple Silicon，省一半时间）"
# --disable-sandbox：SwiftPM 评估 Package.swift 时会调用 sandbox-exec，
# 在我们这个受限环境里会报 Operation not permitted，关掉即可
swift build -c "$CONFIG" --triple arm64-apple-macosx14.0 --disable-sandbox >&2
BIN="$(swift build -c "$CONFIG" --triple arm64-apple-macosx14.0 --disable-sandbox --show-bin-path)/$BIN_NAME"

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
  <key>LSMinimumSystemVersion</key><string>14.0</string>
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
