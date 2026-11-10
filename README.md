# <img src="assets/icon.png" width="32" alt="" align="top"> fairy cursor

a little glass bead that follows your cursor and carries your screenshots.

## install

needs macos 26 and xcode 26 (or just its command line tools: `xcode-select --install`).

```sh
git clone https://github.com/Rrrima/fairy-cursor && cd fairy-cursor
scripts/bundle.sh
cp -R "build/Fairy Cursor.app" /Applications/
open "/Applications/Fairy Cursor.app"
```

the first build takes a minute or two. the fairy lives in the menu bar.

then turn it on in **system settings → privacy & security**:

1. **accessibility** → fairy cursor
2. **screen recording** → fairy cursor
3. quit fairy from the menu bar and open it again

after you rebuild, macos may forget these. turn them off and on again.

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

## develop

```sh
scripts/bundle.sh --run   # rebuild and relaunch
swift test
```

`scripts/bundle.sh --release` is for maintainers making the official download. you don't need it.

built on [ausm](https://github.com/foundation-interface/AUSM).
