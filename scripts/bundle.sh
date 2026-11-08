#!/bin/bash
# Build FairyCursor in release mode and wrap it in a .app bundle at build/Fairy Cursor.app.
# Usage: scripts/bundle.sh [--run]
set -euo pipefail
cd "$(dirname "$0")/.."
export AUSM_ROOT="${AUSM_ROOT:-../AUSM-releasing}"

swift build -c release 2>&1 | grep -E "error|warning: var|Compiling|Build complete" || true
BIN=".build/release/FairyCursor"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

APP="build/Fairy Cursor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FairyCursor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -d Resources/Fonts ] && cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# Sign with a stable identity so macOS keeps the Accessibility / Screen Recording grants across
# rebuilds (an ad-hoc signature changes every build and silently drops them). Falls back to
# ad-hoc when the local certificate isn't in the keychain.
LOCAL_IDENTITY="Fairy Cursor Local Signing"
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
  SIGN_IDENTITY="$LOCAL_IDENTITY"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.rima.fairycursor "$APP" >/dev/null 2>&1
echo "bundled: $APP"

if [ "${1:-}" = "--run" ]; then
  pkill -x FairyCursor >/dev/null 2>&1 || true
  open "$APP"
fi
