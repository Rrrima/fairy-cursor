#!/bin/bash
# build fairy cursor and wrap it in build/Fairy Cursor.app.
#
# usage:
#   scripts/bundle.sh             build for this mac
#   scripts/bundle.sh --run       build, then (re)launch it
#   scripts/bundle.sh --release   universal build, developer id signing, notarization -> build/fairy-cursor.zip
#   scripts/bundle.sh --zip       universal build, ad-hoc signed, not notarized -> build/fairy-cursor.zip
#                                 (for shipping before you have a developer id; people open it with
#                                 system settings → privacy & security → open anyway)
#
# --release needs a "Developer ID Application" certificate in your keychain and notary
# credentials saved once with:
#   xcrun notarytool store-credentials fairy --apple-id <apple id> --team-id <team id>
# override with SIGN_IDENTITY=... and NOTARY_PROFILE=...
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
APP="build/Fairy Cursor.app"
ZIP="build/fairy-cursor.zip"

if [ "$MODE" = "--release" ]; then
  # find the signing identity before the slow build, so a missing certificate fails fast
  if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
  fi
  [ -n "$SIGN_IDENTITY" ] || { echo "no \"Developer ID Application\" certificate found in the keychain"; exit 1; }
  NOTARY_PROFILE="${NOTARY_PROFILE:-fairy}"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "no notary credentials named \"$NOTARY_PROFILE\" (see the top of this script)"; exit 1; }

  swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|Build complete" || true
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/FairyCursor"
elif [ "$MODE" = "--zip" ]; then
  swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error|Build complete" || true
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/FairyCursor"
else
  swift build -c release 2>&1 | grep -E "error|warning: var|Compiling|Build complete" || true
  BIN=".build/release/FairyCursor"
fi
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FairyCursor"
cp resources/Info.plist "$APP/Contents/Info.plist"
[ -f resources/app-icon.icns ] && cp resources/app-icon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -d resources/fonts ] && cp -R resources/fonts "$APP/Contents/Resources/Fonts"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if [ "$MODE" = "--release" ]; then
  codesign --force --options runtime --timestamp --entitlements resources/entitlements.plist \
    --sign "$SIGN_IDENTITY" --identifier com.rima.fairycursor "$APP"
  codesign --verify --strict --deep "$APP"

  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "notarizing (usually a few minutes)..."
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  # zip again so the download carries the stapled ticket and opens offline too
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute "$APP" && echo "gatekeeper: accepted"
  echo "release: $ZIP"
  exit 0
fi

if [ "$MODE" = "--zip" ]; then
  codesign --force --sign - --identifier com.rima.fairycursor "$APP"
  codesign --verify --strict "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "release (not notarized): $ZIP"
  exit 0
fi

# Sign with a stable identity so macOS keeps the Accessibility / Screen Recording grants across
# rebuilds (an ad-hoc signature changes every build and silently drops them). Falls back to
# ad-hoc when the local certificate isn't in the keychain.
LOCAL_IDENTITY="Fairy Cursor Local Signing"
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
  SIGN_IDENTITY="$LOCAL_IDENTITY"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.rima.fairycursor "$APP" >/dev/null 2>&1
echo "bundled: $APP"

if [ "$MODE" = "--run" ]; then
  pkill -x FairyCursor >/dev/null 2>&1 || true
  open "$APP"
fi
