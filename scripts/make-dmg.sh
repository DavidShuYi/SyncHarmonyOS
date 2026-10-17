#!/bin/bash
# make-dmg.sh — package dist/SyncHarmonyOS.app into a distributable DMG.
#
# Usage: scripts/make-dmg.sh
# Prerequisite: scripts/build-app.sh has produced dist/SyncHarmonyOS.app
#
# Output: dist/SyncHarmonyOS-1.0.0.dmg (compressed UDZO, drag-to-Applications layout)

set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/SyncHarmonyOS.app"
VERSION="1.0.0"
STAGING="dist/dmg-staging"
DMG="dist/SyncHarmonyOS-$VERSION.dmg"

[[ -d "$APP" ]] || { echo "error: $APP missing — run scripts/build-app.sh first" >&2; exit 1; }

echo "==> staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> hdiutil create"
hdiutil create -volname "SyncHarmonyOS" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGING"
echo "==> done: $DMG"
ls -lh "$DMG"
