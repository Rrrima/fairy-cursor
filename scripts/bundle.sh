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
#
# for trying an update on this mac (see "updates" in the readme), a plain build also takes:
#   VERSION=0.4.1 BUILD=5   the version the bundle says it is
#   FEED_URL=http://...     where it looks for updates, instead of the website
#   HARDENED=1              sign like a release (hardened runtime, entitlements), without notarizing
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

# sparkle (the updater) rides inside the app, where the binary is told to look for it
SPARKLE=$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework | head -1)
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/FairyCursor" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/FairyCursor" 2>/dev/null
fi

PLIST="$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"; fi
if [ -n "${BUILD:-}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"; fi
if [ -n "${FEED_URL:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$PLIST"
  # sparkle refuses a plain-http feed unless the app says it may load one: test builds only
  case "$FEED_URL" in http://*)
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$PLIST" ;;
  esac
fi

# sign the app and what's inside it. a signature covers everything under it, so sparkle's
# helpers go first, innermost first, and the app last.
#   sign_app <app> <identity> <hardened: yes|no> <timestamp flag>
sign_app() {
  local app="$1" identity="$2" hardened="$3" stamp="$4"
  local fw="$app/Contents/Frameworks/Sparkle.framework"
  local flags=(--force --sign "$identity" "$stamp")
  local own=(--identifier com.rima.fairycursor)
  if [ "$hardened" = yes ]; then
    flags+=(--options runtime)
    own+=(--entitlements resources/entitlements.plist)
  fi
  codesign "${flags[@]}" "$fw/Versions/B/XPCServices/Installer.xpc"
  codesign "${flags[@]}" --preserve-metadata=entitlements "$fw/Versions/B/XPCServices/Downloader.xpc"
  codesign "${flags[@]}" "$fw/Versions/B/Autoupdate"
  codesign "${flags[@]}" "$fw/Versions/B/Updater.app"
  codesign "${flags[@]}" "$fw"
  codesign "${flags[@]}" "${own[@]}" "$app"
}

if [ "$MODE" = "--release" ]; then
  sign_app "$APP" "$SIGN_IDENTITY" yes --timestamp
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
  # sign a copy: re-signing the app you run locally would drop its accessibility and screen
  # recording grants, and the fairy on this mac would stop working
  STAGE=$(mktemp -d)
  ditto "$APP" "$STAGE/Fairy Cursor.app"
  sign_app "$STAGE/Fairy Cursor.app" - no --timestamp=none 2>/dev/null
  codesign --verify --strict --deep "$STAGE/Fairy Cursor.app"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$STAGE/Fairy Cursor.app" "$ZIP"
  rm -rf "$STAGE"
  # and keep the local copy on the stable local identity (see below)
  if security find-certificate -c "Fairy Cursor Local Signing" >/dev/null 2>&1; then
    sign_app "$APP" "Fairy Cursor Local Signing" no --timestamp=none >/dev/null 2>&1
  fi
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
HARD=no; if [ "${HARDENED:-}" = 1 ]; then HARD=yes; fi
sign_app "$APP" "${SIGN_IDENTITY:--}" "$HARD" --timestamp=none >/dev/null 2>&1 || echo "warning: signing failed"
echo "bundled: $APP"

if [ "$MODE" = "--run" ]; then
  pkill -x FairyCursor >/dev/null 2>&1 || true
  open "$APP"
fi
