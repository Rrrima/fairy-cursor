import AppKit

// Menu-bar-only app (LSUIElement in Info.plist); no storyboard, no @main.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
