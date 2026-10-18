#!/bin/bash
#
#  File:    build-app.sh
#  Project: SyncHarmonyOS
#  Author:  David Zhang
#  Version: 1.0.0
#  Date:    2026-10-18
#  License: MIT
#

# build-app.sh — build SyncHarmonyOS.app from source.
#
# Usage:
#   scripts/build-app.sh [release|debug]
#
# Steps:
#   1. swift build (universal arm64+x86_64 for release)
#   2. assemble the .app bundle (Info.plist, binary, icon)
#   3. ad-hoc codesign
#
# Output: dist/SyncHarmonyOS.app

set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
if [[ "$CONFIG" == "release" ]]; then
    SWIFT_FLAGS=(-c release --arch arm64 --arch x86_64)
    BIN_DIR=".build/arm64-apple-macosx/release"
else
    SWIFT_FLAGS=(-c debug)
    BIN_DIR=".build/debug"
fi

echo "==> swift build ${SWIFT_FLAGS[*]}"
swift build "${SWIFT_FLAGS[@]}" --product SyncHarmonyOS
swift build "${SWIFT_FLAGS[@]}" --product syncharmony

# Universal builds land in .build/apple/Products/<config>; single-arch in .build/<config>.
if [[ -d ".build/apple/Products/Release" ]]; then
    BIN_DIR=".build/apple/Products/Release"
else
    BIN_DIR="$BIN_DIR"
fi

APP="dist/SyncHarmonyOS.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BIN_DIR/SyncHarmonyOS" "$MACOS/SyncHarmonyOS"
cp "$BIN_DIR/syncharmony" "$MACOS/syncharmony"
chmod +x "$MACOS"/*

# Icon: generate when missing.
if [[ ! -f "$RESOURCES/AppIcon.icns" ]]; then
    echo "==> generating icon"
    swift scripts/make-icon.swift .build/icon.iconset
    iconutil -c icns .build/icon.iconset -o "$RESOURCES/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                     <string>SyncHarmonyOS</string>
    <key>CFBundleDisplayName</key>              <string>SyncHarmonyOS</string>
    <key>CFBundleExecutable</key>               <string>SyncHarmonyOS</string>
    <key>CFBundleIdentifier</key>               <string>io.github.syncharmonyos.app</string>
    <key>CFBundleVersion</key>                  <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>       <string>1.0.0</string>
    <key>CFBundlePackageType</key>              <string>APPL</string>
    <key>CFBundleIconFile</key>                 <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>           <string>13.0</string>
    <key>LSApplicationCategoryType</key>        <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>          <true/>
    <key>NSHumanReadableCopyright</key>         <string>MIT License — SyncHarmonyOS contributors</string>
    <key>CFBundleDevelopmentRegion</key>        <string>zh-Hans</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
# Sign helper binaries first, then the bundle itself.
codesign --force --sign - "$MACOS/syncharmony"
codesign --force --sign - "$APP"

echo "==> done: $APP"
