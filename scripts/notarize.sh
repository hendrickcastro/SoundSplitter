#!/usr/bin/env bash
# Sign (Developer ID + hardened runtime), build, notarize and staple the DMG,
# so downloads open with no Gatekeeper warning — the same result as apps like
# FineTune.
#
# Prerequisites (one-time, using your PAID Apple Developer account):
#   1. A "Developer ID Application" certificate installed in your keychain.
#      Create it at https://developer.apple.com/account → Certificates → +
#      → "Developer ID Application", download and double-click to install.
#   2. A notarytool credential profile named "soundsplitter" (or set NOTARY_PROFILE):
#        xcrun notarytool store-credentials soundsplitter \
#          --apple-id "TU_APPLE_ID" \
#          --team-id  "TU_TEAM_ID" \
#          --password "APP_SPECIFIC_PASSWORD"   # appleid.apple.com → app-specific password
#
# Usage: ./scripts/notarize.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SoundSplitter"
APP="$ROOT/.build/${APP_NAME}.app"
NOTARY_PROFILE="${NOTARY_PROFILE:-soundsplitter}"

# 1. Resolve the Developer ID Application identity.
IDENTITY="${DEVELOPER_ID:-$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')}"
if [[ -z "$IDENTITY" ]]; then
    echo "error: no 'Developer ID Application' certificate found in your keychain." >&2
    echo "       Create one at https://developer.apple.com/account (Certificates)." >&2
    exit 1
fi
echo "==> Signing identity: $IDENTITY"

# 2. Build + assemble the .app (ad-hoc), then re-sign with Developer ID + hardened runtime.
bash "$ROOT/scripts/bundle.sh" release
echo "==> Re-signing with Developer ID + hardened runtime…"
codesign --force --deep --options runtime --timestamp \
    --entitlements "$ROOT/Resources/${APP_NAME}.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Build the DMG (uses the just-signed .app) and sign it too.
bash "$ROOT/scripts/make-dmg.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG="$ROOT/${APP_NAME}-${VERSION}.dmg"
echo "==> Signing DMG…"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# 4. Notarize and wait.
echo "==> Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

# 5. Staple the ticket so it works offline.
echo "==> Stapling…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# 6. Refresh the copies (Desktop + APP/).
cp -f "$DMG" "$ROOT/APP/" 2>/dev/null || true
[[ -d "$HOME/Desktop" ]] && cp -f "$DMG" "$HOME/Desktop/"

echo "==> Notarized DMG ready: $DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | head -3 || true
