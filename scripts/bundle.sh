#!/usr/bin/env bash
# Build SoundSplitter and package it into a runnable .app bundle.
# Usage: ./scripts/bundle.sh [debug|release]  (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SoundSplitter"
APP="$ROOT/.build/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$MACOS" "$CONTENTS/Resources"
cp "$BIN" "$MACOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

echo "==> Codesigning (ad-hoc)…"
codesign --force --deep \
    --sign - \
    --entitlements "$ROOT/Resources/$APP_NAME.entitlements" \
    "$APP"

echo "==> Done: $APP"
echo "    Run it with:  open \"$APP\""
