# Fairy Cursor

A tiny native macOS companion that trails your cursor as a bead of liquid glass. Take a
screenshot (⌘⇧3 / ⌘⇧4 / ⌘⇧5, with or without ⌃ for clipboard) and the fairy picks it up and
carries a thumbnail with it. Then:

- **shake the cursor** to let the top one go; **keep shaking** (about 1.5 s) to drop the whole pile,
- **double-click an empty spot on the Desktop or in a Finder window** to put the PNG there,
- **double-click in any text input** (chat box, document, web form) to paste it.

When it carries several, a double-click delivers **all of them**, top card first (one paste after
another, or every PNG saved into the folder). Double-click inside a fairy note and they're added
to the note (saved to `Notes/attachments/`, shown as thumbnails under the text).

It never appears in the screenshots it carries, it steps aside while the system screenshot UI
is up, and it hands your previous clipboard back after pasting.

By default it **replaces** macOS's own screenshot aftermath: no floating thumbnail in the corner
and no file dropped on the Desktop (macOS still writes the file, into
`~/Library/Application Support/Fairy Cursor/Captures`, which the fairy purges). The original
settings are restored when you turn the menu item off or quit. The fairy is invisible while it
holds nothing ("Show Fairy When Empty" in the menu turns the idle bead on).

## Sticky notes

Hold **⌥** on its own over empty space (the Desktop, a page margin, a window's background) and a
glass pill rings the cursor. Click while it shows and a note grows out of it; the click never
reaches the app underneath. Notes are glass panels you can drag (header/footer) and resize
(bottom-right grip), written in Markdown that is styled as you type (headings, **bold**, *italic*,
`code`, ~~strike~~, links, `- [ ]` tasks; Return continues a list).

Each note autosaves to `~/Library/Application Support/Fairy Cursor/Notes/<id>.json` with its
created/edited times and where it was started. That's either the Desktop, an app (plus window
title and document path when the app exposes one) or a web page (URL from the browser's
accessibility tree, falling back to AppleScript for Safari/Chromium). The chip in the header goes
back there. The menu-bar menu lists every note (⌥ turns each item into Delete), plus New Note,
Show All / Put Away All, the notes folder and an on/off switch for the ⌥ gesture.
Putting an empty note away deletes it.

## How it is built

- Native Swift / SwiftUI, menu-bar only, macOS 26 (uses the real Liquid Glass `glassEffect`).
- Screenshot and cursor detection come from **AUSM**'s `device-macos` kits
  (`ScreenshotMonitorKit`, `CursorMonitorKit`), linked in-process through the
  `device-macos/Package.swift` umbrella package on AUSM's `releasing_branch`.
- Visual tokens are ported from agentic-web's "Liquid Clarity" glass system
  (`host/resources/chrome/styles.css`): cool blue-grey neutrals, hairline borders, a white 135°
  plate over glass, soft slate shadows, one blue accent.

```
Sources/FairyCursor/
  AppDelegate.swift   wires the AUSM monitors to the fairy, menu bar item
  FairyPanel.swift    click-through, always-on-top, capture-excluded NSPanel
  FairyView.swift     SwiftUI glass orb ⇄ card (GlassEffectContainer morph)
  Follower.swift      120 Hz spring that trails the cursor, flips near screen edges
  ShakeDetector.swift horizontal direction-reversal counter
  DropRouter.swift    double-click → Finder save / text paste
  FinderTarget.swift  folder resolution (AX window → Finder AppleScript) + PNG write
  PasteTarget.swift   pasteboard swap, →, ⌘V, clipboard restore; Chromium AX switch
  Theme.swift         agentic-web tokens
  NoteSummoner.swift  ⌥-hold detection, summon pill, click-swallowing event tap
  NoteContext.swift   empty-spot test + note origin (Desktop / app / web URL)
  NoteStore.swift     Note model, JSON persistence with debounced writes
  NoteView.swift      glass note panel, drag/resize, summon pill view
  MarkdownEditor.swift NSTextView with live Markdown styling and list continuation
  NotesController.swift note panels lifecycle + menu section
```

## Build & run

```bash
# AUSM releasing_branch checkout (worktree) is expected at ../AUSM-releasing,
# or set AUSM_ROOT=/path/to/AUSM
scripts/bundle.sh --run        # builds build/Fairy Cursor.app and opens it
```

First launch asks for **Accessibility** (cursor + double-click tracking) and **Screen Recording**
(reproducing the capture). Saving into a Finder window also asks once for **Automation → Finder**.
The menu-bar sparkle shows permission state and has "Launch at Login".

Debug: `FAIRY_DEBUG=1` logs to stderr; `FAIRY_CAPTURABLE=1` lets the fairy appear in screenshots
(for taking pictures of it); `--demo` starts holding a crop of the main display.

## Notes & limits

- Browsers and Electron apps only expose web inputs to accessibility once asked. The fairy flips
  that switch (`AXEnhancedUserInterface`) on every running Chromium/Electron app at launch and on
  apps launched later, so chat boxes in Chrome, Arc, Slack, Discord, Notion, Cursor… are recognised.
  (Chrome then runs with full accessibility on; that is the same mode VoiceOver uses.)
- Paste keystrokes are posted directly to the process that owns the clicked field, so they cannot
  land in a different frontmost app.
- Launching from Finder/`open` runs under the app's own identity: grant Accessibility and
  Screen Recording to "Fairy Cursor" when prompted. Launching the binary from a terminal inherits
  the terminal's grants.
- A double-click in a text field selects a word; the fairy presses → before ⌘V so the paste
  inserts after the word instead of replacing it.
- ⌘⇧5 panel: Return or the Capture button triggers the fairy's capture; the captured area follows
  the panel's remembered style (selection / window / screen).
