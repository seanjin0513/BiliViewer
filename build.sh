#!/bin/bash
# BiliViewer 一键构建脚本
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BiliViewer"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

cd "$ROOT"

echo "==> [1/5] 生成应用图标"
mkdir -p "$BUILD_DIR"
swift scripts/make_icon.swift "$BUILD_DIR/AppIcon.png"
mkdir -p "$BUILD_DIR/AppIcon.iconset"
ICONSET="$BUILD_DIR/AppIcon.iconset"
for size in 16 32 64 128 256 512 1024; do
  sips -z $size $size "$BUILD_DIR/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
# @2x 变体
sips -z 32 32 "$BUILD_DIR/AppIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 64 64 "$BUILD_DIR/AppIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 256 256 "$BUILD_DIR/AppIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 512 512 "$BUILD_DIR/AppIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "==> [2/5] 编译 Swift 源码"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
swiftc -O \
  -framework AppKit -framework WebKit \
  -o "$CONTENTS/MacOS/$APP_NAME" \
  Sources/main.swift Sources/BrowserWindow.swift Sources/SystemVolume.swift

echo "==> [3/5] 组装 Bundle"
cp Info.plist "$CONTENTS/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> [4/5] Ad-hoc 签名"
codesign --force --deep -s - "$APP_DIR"

echo "==> [5/5] 打包 DMG"
rm -rf "$BUILD_DIR/dmg-staging" "$BUILD_DIR/$APP_NAME.dmg"
mkdir -p "$BUILD_DIR/dmg-staging"
cp -R "$APP_DIR" "$BUILD_DIR/dmg-staging/"
ln -s /Applications "$BUILD_DIR/dmg-staging/Applications"
hdiutil create -volname "$APP_NAME" -fs HFS+ -srcfolder "$BUILD_DIR/dmg-staging" -ov -format UDZO "$BUILD_DIR/$APP_NAME.dmg" >/dev/null 2>&1
rm -rf "$BUILD_DIR/dmg-staging"

echo "==> 完成"
echo "应用位置: $APP_DIR"
echo "DMG 位置: $BUILD_DIR/$APP_NAME.dmg"
