#!/usr/bin/env bash
# Build a distributable .dmg containing SoundSplitter.app.
# Depends on scripts/bundle.sh having produced (or being able to produce) the app.
# Usage: ./scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SoundSplitter"
APP="$ROOT/.build/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo 0.1.0)"
# Output to the project root (visible in Finder), not the hidden .build dir.
DMG="$ROOT/${APP_NAME}-${VERSION}.dmg"
STAGING="$ROOT/.build/dmg-staging"

# Ensure the app exists (build it if needed).
if [[ ! -d "$APP" ]]; then
    echo "==> App not found, building it first…"
    bash "$ROOT/scripts/bundle.sh" release
fi

echo "==> Staging DMG contents…"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
# Drag-to-install target.
ln -s /Applications "$STAGING/Applications"

echo "==> Creating ${DMG}…"
rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGING"

# Also drop a copy on the Desktop for easy access.
DESKTOP="$HOME/Desktop"
if [[ -d "$DESKTOP" ]]; then
    cp -f "$DMG" "$DESKTOP/" && echo "==> Copia en: $DESKTOP/$(basename "$DMG")"
fi

SIZE="$(du -h "$DMG" | cut -f1)"
echo "==> Done: $DMG ($SIZE)"
echo "    Ábrelo con:  open \"$DMG\""
