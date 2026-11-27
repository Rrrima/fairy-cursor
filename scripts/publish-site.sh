#!/bin/bash
# publish the website: site/ plus the latest release's zip and the update feed (appcast.xml)
# that installed copies read, to the gh-pages branch.
# github pages serves that branch, and rrrima.me (netlify) passes /fairy-cursor/ through to it:
# https://rrrima.me/fairy-cursor/
#
# usage:
#   scripts/publish-site.sh           the latest release
#   scripts/publish-site.sh v0.3.0    a given release
#
# run it after `gh release create`, and whenever site/ changes.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp -R site/. "$OUT/"
touch "$OUT/.nojekyll"
# shellcheck disable=SC2086
gh release download $TAG --pattern fairy-cursor.zip --dir "$OUT"

# the update feed: this release, downloaded from github (a url that never changes under an
# installed copy mid-update), with the release's notes as what the update window shows.
RELEASE=$(gh release view $TAG --json tagName -q .tagName)
REPO=$(gh repo view --json url -q .url)
NOTES=$(mktemp)
gh release view "$RELEASE" --json body -q .body | scripts/notes-html.sh > "$NOTES"
scripts/appcast.sh "$OUT/fairy-cursor.zip" "$REPO/releases/download/$RELEASE/fairy-cursor.zip" "$NOTES" > "$OUT/appcast.xml"
rm -f "$NOTES"

# one commit, replaced each time: the branch never piles up old zips
REMOTE=$(git remote get-url origin)
git -C "$OUT" init -q -b gh-pages
git -C "$OUT" add -A
git -C "$OUT" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
  commit -q -m "site: $(git rev-parse --short HEAD)${TAG:+, $TAG}"
git -C "$OUT" push -q --force "$REMOTE" gh-pages
echo "published. https://rrrima.me/fairy-cursor/"
