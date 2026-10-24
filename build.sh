#!/bin/bash
# 编译并打包成 build/TermGrid.app；加 --zip / --dmg 同时生成安装包
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"

# 通用二进制：同时支持 Apple 芯片和 Intel
ARCH_FLAGS=(-c release --arch arm64 --arch x86_64)
swift build "${ARCH_FLAGS[@]}"
BIN="$(swift build "${ARCH_FLAGS[@]}" --show-bin-path)/TermGrid"
APP=build/TermGrid.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TermGrid"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TermGrid</string>
    <key>CFBundleDisplayName</key><string>TermGrid</string>
    <key>CFBundleIdentifier</key><string>local.termgrid</string>
    <key>CFBundleExecutable</key><string>TermGrid</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier local.termgrid "$APP"
echo "✅ 已生成 $APP"

for arg in "$@"; do
  case "$arg" in
    --zip)
      ZIP="build/TermGrid-$VERSION.zip"
      rm -f "$ZIP"
      ditto -c -k --keepParent "$APP" "$ZIP"
      echo "✅ 已生成 $ZIP"
      ;;
    --dmg)
      # 拖拽安装用的 dmg：里面放 TermGrid.app 和一个「应用程序」的快捷方式
      DMG="build/TermGrid-$VERSION.dmg"
      STAGE=$(mktemp -d)
      cp -R "$APP" "$STAGE/"
      ln -s /Applications "$STAGE/Applications"
      cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
      # 先做可写镜像，挂载后打上"自定义图标"标记（-srcfolder 不会保留根目录属性），再压缩
      RW="$STAGE.rw.dmg"
      hdiutil create -volname "TermGrid" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
      MNT=$(mktemp -d)
      hdiutil attach "$RW" -nobrowse -mountpoint "$MNT" >/dev/null
      SetFile -a C "$MNT"
      hdiutil detach "$MNT" >/dev/null
      rm -f "$DMG"
      hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
      rm -rf "$STAGE" "$RW" "$MNT"
      echo "✅ 已生成 $DMG"
      ;;
  esac
done
