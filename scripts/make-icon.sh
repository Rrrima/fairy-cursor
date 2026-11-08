#!/bin/bash
# regenerate resources/app-icon.icns from scripts/make-icon.swift (the liquid-glass bead).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swift scripts/make-icon.swift "$TMP/icon-1024.png"
swift scripts/make-icon.swift "$TMP/bead.png" --bead-only
sips -c 440 440 "$TMP/bead.png" --out "$TMP/bead-crop.png" >/dev/null
sips -z 128 128 "$TMP/bead-crop.png" --out assets/icon.png >/dev/null
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o resources/app-icon.icns
rm -rf "$TMP"
echo "wrote resources/app-icon.icns"
