# <picture><source media="(prefers-color-scheme: dark)" srcset="assets/icon-dark.png"><img src="assets/icon.png" width="32" alt="" align="top"></picture> fairy cursor

a cursor that helps with little things. it carries your screenshots: take one, then double-click where it should go. it also takes notes and records your screen.

needs macos 26.

## download

grab [`fairy-cursor.zip`](https://rrrima.me/fairy-cursor/fairy-cursor.zip) (or visit [the website](https://rrrima.me/fairy-cursor/)), unzip it and open **fairy cursor**. it offers to move itself into `/Applications`; say yes, so macos lists it by name and its permissions stick.

it's signed and notarized, so it opens like any other app. from 0.5.0 on it updates itself: menu bar → **check for updates…**

## build from source

you need xcode 26, or just its command line tools (`xcode-select --install`).

```sh
git clone https://github.com/Rrrima/fairy-cursor && cd fairy-cursor
scripts/bundle.sh
```

that builds `build/Fairy Cursor.app` (the first build takes a minute or two). to install it:

```sh
cp -R "build/Fairy Cursor.app" /Applications/
```

## run

```sh
open "/Applications/Fairy Cursor.app"
```

it lives in the menu bar; there's no dock icon. the first time, a welcome card asks for two permissions, one at a time:

1. press **allow** next to **accessibility**, and switch fairy cursor on in the system settings pane that opens
2. the same for **screen recording**
3. quit fairy cursor from the menu bar and open it again

you can also switch both on yourself in **system settings → privacy & security**.

after you rebuild, macos may forget these. turn them off and on again.

## use

- `⌘ ⇧ 3` `⌘ ⇧ 4` `⌘ ⇧ 5` take a screenshot. fairy cursor picks it up
- double-click a text box to paste it
- double-click a slide or a board (keynote, google slides, figma, excalidraw…) to drop it there
- double-click in a google doc to drop it after the word you clicked
- double-click the desktop or a finder window to save it as a png
- shake to let the top one go. keep shaking to drop them all
- hold `⌥` on empty space, then click, to start a sticky note

dropped one by accident? menu bar → restore last screenshot. your notes are under menu bar → recent notes.

## record your screen

- `⌘ ⇧ 6` starts recording the screen your cursor is on. press it again to stop
- while recording, hold `⌥` and scroll to zoom in and out
- hold `⌥` and move the cursor to move the zoomed view with it. let go and the view stays put
- tap `⌥` twice to go back to the whole screen
- the cursor gets bigger while you record, and goes back when you stop
- `⌘ ⇧ 7` turns the cursor into a pen, `⌘ ⇧ 8` into a highlighter. press the other one to switch, the same one again to go back to the cursor. the ink is in the video
- while drawing: `⌘ Z` takes back the last stroke, `⌫` clears the screen, `esc` puts the pen down (and the ink fades away)
- `⌘ ⇧ 9` pauses the recording and opens the sound panel: switch on **computer sound**, the **microphone** (and pick which one), both or neither. `1` and `2` flip the switches, `↑` `↓` pick the microphone, `return` keeps recording. sound is off until you switch it on, and the choice is remembered
- the first time you switch the microphone on, macos asks whether fairy cursor may use it
- when you stop, fairy cursor picks the recording up like a screenshot: double-click a text box to share it. the file is saved next to your screenshots

the blue outline shows what's being recorded; it isn't in the video. on a mac with a touch bar, `⌘ ⇧ 6` normally screenshots the touch bar; fairy cursor uses it for recording instead.

## settings

menu bar → settings…

- **capabilities**: screenshots, notes and screen recording each switch on and off on their own. switch one off and it lets go of everything it took over (screenshots go back to macos, `⌘ ⇧ 6` back to the system)
- **keep every screenshot**: off by default, so a screenshot is only saved where you drop it and shaking throws it away. turn it on and every screenshot is saved to a folder you pick as you take it, and shaking just lets go
- **notes folder**: each note is a markdown file there (`~/Documents/Fairy Notes` by default), so you can open, edit and sync them like any other file
- **following**: how what you hold travels after the cursor. **close** stays right by it, **calm** glides after it (the default), **lively** swings and leans as you move, like the demo on the website
- **captures folder**: where kept screenshots and recordings go (where macos saved screenshots, by default)
- **updates**: which version you have, a button to look for a newer one, and whether to look by itself (about once a day)

## permissions

- accessibility: follow the cursor, see what's under it, paste
- screen recording: capture the screenshot you just took

nothing leaves your mac. the one thing fairy cursor fetches is its update feed from the website, about once a day (**settings → updates** switches that off); it sends nothing about you with it.

## change how it works

fairy cursor doesn't take screenshots itself. it notices yours, so to use different screenshot keys, change them in **system settings → keyboard → keyboard shortcuts → screenshots** and fairy cursor follows.

everything that watches what you do comes from [ausm](https://github.com/foundation-interface/ausm), an open toolkit for reacting to activity on your mac. if you want fairy cursor to react to something else, start there:

- **screenshots**: `ScreenshotMonitorKit` ([`device-macos/screenshot-detector`](https://github.com/foundation-interface/ausm/tree/main/device-macos/screenshot-detector)) works out when a `⌘ ⇧ 3/4/5` screenshot is taken and recaptures it
- **cursor and clicks**: `CursorMonitorKit` ([`device-macos/cursor-plus-plus`](https://github.com/foundation-interface/ausm/tree/main/device-macos/cursor-plus-plus)) reports moves and double-clicks, and what's under the cursor

fairy cursor's own gestures live in this repo:

- shake: `sources/core/ShakeDetector.swift` (how far, how fast, how many times)
- what a double-click does where: `sources/core/DropPolicy.swift`, `sources/core/PastePolicy.swift`
- hold `⌥` for a note: `sources/capabilities/notes/NoteSummoner.swift`
- the recording shortcuts, `⌥` + scroll and the pen keys: `sources/capabilities/recording/RecordingInput.swift`
- the pen and highlighter: `sources/capabilities/recording/InkOverlay.swift` (look) and `sources/core/Ink.swift` (behaviour)
- how ausm is wired in: `sources/capabilities/screenshots/ScreenshotsCapability.swift` and `startCursorMonitor()` in `sources/app/AppDelegate.swift`

## capabilities

fairy cursor itself does three things: it follows your cursor, carries screenshots, and drops them where you double-click. everything else it can do is a **capability**: a separate module you can switch on and off in **settings → capabilities**.

### what's in it now

| capability | id | what it does | shortcut | needs |
|---|---|---|---|---|
| screenshots | `fairy.screenshots` | takes over macos screenshots, so fairy cursor carries each one instead of a file on the desktop | `⌘ ⇧ 3` `⌘ ⇧ 4` `⌘ ⇧ 5` | screen recording |
| notes | `fairy.notes` | sticky notes saved as markdown; double-click one to drop screenshots into it | hold `⌥`, click | accessibility |
| screen recording | `fairy.screen-recording` | records the screen under the cursor, with `⌥` + scroll zoom and a pen and highlighter | `⌘ ⇧ 6`, `⌘ ⇧ 7`, `⌘ ⇧ 8`, `⌘ ⇧ 9` | screen recording, accessibility (and the microphone, only if you switch it on) |

switch one off and it gives back everything it took over: screenshots go back to macos, `⌘ ⇧ 6` back to the system, and a recording in progress is saved first. the menu and the permission prompts only show what the switched-on capabilities need.

### how it's put together

```
sources/
  kit/            FairyKit: what a capability is written against
  capabilities/
    screenshots/  one module per capability
    notes/
    recording/
  app/            the host: the app itself, the menu, settings, and the list of capabilities
  core/           pure logic, unit-tested
```

- a capability imports `FairyKit` (and `FairyCore` if it wants), never another capability. so you can remove one without breaking the others
- anything capabilities share goes through the host (`FairyHost`): what fairy cursor is carrying, whether the screen is busy, where captures are saved. that's how recording keeps `⌥` for its zoom and notes stay quiet meanwhile
- the host creates every capability once, calls `activate` when it's switched on and `deactivate` when it's switched off or the app quits

### add one

1. make a folder `sources/capabilities/hello/` with a type that conforms to `Capability`:

```swift
import AppKit
import FairyKit

@MainActor
public final class HelloCapability: Capability {
    public static let manifest = CapabilityManifest(
        id: "com.you.hello", name: "Hello", summary: "says hello from the menu.")

    private weak var host: FairyHost?
    public init() {}

    public func activate(host: FairyHost) { self.host = host }
    public func deactivate() { host = nil }

    public func menuItems() -> [NSMenuItem] {
        [ActionMenuItem("Say Hello") { NSSound.beep() }]
    }
}
```

2. add a target for it in `Package.swift`, and add it to the `FairyCursor` target's dependencies:

```swift
.target(name: "FairyHello", dependencies: ["FairyKit"], path: "sources/capabilities/hello"),
```

3. list it in `CapabilityRegistry.builtIn` (`sources/app/CapabilityRegistry.swift`), then `scripts/bundle.sh --run`. it shows up in settings → capabilities, switched on.

what a capability can do:

- **`manifest`**: its id (stable forever: it keys the on/off switch), name, one-line summary, the permissions it needs and the shortcuts it takes
- **`activate(host:)` / `deactivate()`**: start your monitors, taps and windows, then stop all of them. `deactivate` must leave the mac as it found it
- **`menuItems()`**: items for the menu bar menu, rebuilt each time it opens (`ActionMenuItem` takes a closure)
- **`settingsView()`**: rows for its own section in settings (`ToggleRow`, `FolderRow` keep it looking like the rest)
- through **`FairyHost`**: hand it a screenshot (`carry`), use what it's carrying (`carried`, `delivered`), hide it while a system ui is up (`setCaptureUIVisible`), have the screen to itself for a while (`setExclusive`), take double-clicks over its own windows (`setDropZone`), and find the captures folder (`capturesFolder`). whatever a capability sets this way is undone for it when it's switched off

capabilities are compiled into the app for now. installing one someone else wrote, without rebuilding, is next.

## develop

```sh
scripts/bundle.sh --run   # rebuild and relaunch
swift test
```

to build against a local ausm checkout instead of the published one:

```sh
AUSM_ROOT=/path/to/ausm scripts/bundle.sh --run
```

to make a release zip (`build/fairy-cursor.zip`, apple silicon and intel):

```sh
scripts/bundle.sh --zip       # ad-hoc signed; people click "open anyway" the first time
scripts/bundle.sh --release   # developer id signed and notarized; see the top of the script
```

to put a release out: bump `CFBundleShortVersionString` and `CFBundleVersion` in `resources/Info.plist`, `gh release create v1.2.3 build/fairy-cursor.zip`, then `scripts/publish-site.sh`. that publishes `site/` and the zip to the website, which is where the download button points, and the update feed.

### updates

installed copies update themselves with [sparkle](https://sparkle-project.org). about once a day (and on **check for updates…**) they read `https://rrrima.me/fairy-cursor/appcast.xml`, which `scripts/publish-site.sh` writes from the latest release: its version, where to download the zip, and a signature. a copy only installs a zip whose signature matches `SUPublicEDKey` in `resources/Info.plist`.

the private half of that key is in the login keychain of the mac that makes releases ("private key for signing sparkle updates"). keep a copy somewhere safe: `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key` writes it to a file, and `-f` reads it back in on another mac. without it, no installed copy accepts a new version.

sparkle compares `CFBundleVersion`, so that number has to go up with every release.

to try an update on your own mac without releasing anything, build an older-looking copy that reads a feed from your own machine (`VERSION`, `BUILD` and `FEED_URL` at the top of `scripts/bundle.sh`), write a feed for the current build with `scripts/appcast.sh`, and serve both from a folder with `python3 -m http.server`.

## license

mit. barlow is under the sil open font license (`resources/fonts/OFL.txt`).
