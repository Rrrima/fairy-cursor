#!/bin/bash
# regenerate resources/app-icon.icns and assets/icon.png (+ icon-dark.png for dark themes) from
# scripts/make-icon.swift, which
# draws the mark defined in sources/app/LogoMark.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
# top-level code must live in main.swift when compiling more than one file
cp scripts/make-icon.swift "$TMP/main.swift"
swiftc -O "$TMP/main.swift" sources/app/LogoMark.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/icon-1024.png"
"$TMP/make-icon" "$TMP/mark.png" --mark-only
sips -z 128 128 "$TMP/mark.png" --out assets/icon.png >/dev/null
"$TMP/make-icon" "$TMP/mark-light.png" --mark-only --light
sips -z 128 128 "$TMP/mark-light.png" --out assets/icon-dark.png >/dev/null
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o resources/app-icon.icns
rm -rf "$TMP"
echo "wrote resources/app-icon.icns"
