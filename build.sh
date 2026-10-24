#!/bin/bash
# 编译并打包成 build/TermGrid.app
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

if [[ "${1:-}" == "--zip" ]]; then
  ZIP="build/TermGrid-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✅ 已生成 $ZIP"
fi
