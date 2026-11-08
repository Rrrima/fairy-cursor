# <img src="assets/icon.png" width="32" alt="" align="top"> fairy cursor

a little glass bead that follows your cursor and carries your screenshots.

## install

download the latest `fairy-cursor.zip` from [releases](https://github.com/Rrrima/fairy-cursor/releases), move the app to `/Applications` and open it. it lives in the menu bar.

needs macos 26.

## use

- `⌘ ⇧ 3` `⌘ ⇧ 4` `⌘ ⇧ 5` take a screenshot. the fairy picks it up
- double-click a text box to paste it
- double-click the desktop or a finder window to save it as a png
- shake to let the top one go. keep shaking to drop them all
- hold `⌥`, then click, to start a sticky note

dropped one by accident? menu bar → restore last screenshot.

## permissions

- accessibility: follow the cursor, see what's under it, paste
- screen recording: capture the screenshot you just took

nothing leaves your mac.

## build

```sh
git clone https://github.com/Rrrima/fairy-cursor && cd fairy-cursor
scripts/bundle.sh --run
swift test
```

built on [ausm](https://github.com/foundation-interface/AUSM).
