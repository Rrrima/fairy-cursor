#!/bin/bash
# write the update feed for a release zip: the one file installed copies of fairy cursor read
# to learn there's a newer version, where to download it, and the signature it must carry.
#
# usage:
#   scripts/appcast.sh <zip> <url the zip is downloaded from> [notes.html] > appcast.xml
#
# the signature is made with the key `generate_keys` put in your keychain (its public half is
# SUPublicEDKey in resources/Info.plist). macos asks once whether sign_update may use it.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="$1"; URL="$2"; NOTES="${3:-}"
BIN=.build/artifacts/sparkle/Sparkle/bin
[ -x "$BIN/sign_update" ] || swift package resolve >/dev/null

INFO=$(mktemp)
trap 'rm -f "$INFO"' EXIT
unzip -p "$ZIP" "Fairy Cursor.app/Contents/Info.plist" > "$INFO"
read_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO"; }
VERSION=$(read_key CFBundleShortVersionString)
BUILD=$(read_key CFBundleVersion)
MINIMUM=$(read_key LSMinimumSystemVersion)
# prints: sparkle:edSignature="…" length="…"
SIGNATURE=$("$BIN/sign_update" "$ZIP")

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Fairy Cursor</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
XML
if [ -n "$NOTES" ] && [ -s "$NOTES" ]; then
  printf '      <description><![CDATA[\n%s\n      ]]></description>\n' "$(cat "$NOTES")"
fi
cat <<XML
      <enclosure url="$URL" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
