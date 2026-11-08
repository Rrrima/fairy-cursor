import Foundation

/// The fairy hides while the system screenshot UI is up. ScreenshotMonitorKit ends an
/// interactive (⌘⇧4 / ⌘⇧5) session on capture, Esc or a 3-minute timeout — but a selection
/// session cancelled any other way (a click without a drag, switching away) stays "open", so the
/// fairy and its screenshots stayed invisible for up to three minutes, and the stale session
/// would turn the next ordinary drag into a phantom capture.
///
/// This watches whether the screenshot UI's overlay is actually on screen. Only once it has been
/// seen *and* then gone for `goneGrace` is the session declared stale. If the overlay is never
/// seen (unknown window layout) nothing changes, so the worst case is the old behaviour.
public struct CaptureWatchdog {
    /// The overlay also disappears the moment a real selection is made, and the monitor's own
    /// capture (ScreenCaptureKit) can take a second or more to arrive after that, so the grace
    /// must comfortably exceed a slow capture.
    public var goneGrace: TimeInterval = 3.0

    private var active = false
    private var interactive = false
    private var sawOverlay = false
    private var goneSince: TimeInterval?
    public private(set) var isStale = false

    public init() {}

    public var isWatching: Bool { active && interactive && !isStale }

    public mutating func sessionStarted(interactive: Bool) {
        active = true
        self.interactive = interactive
        sawOverlay = false
        goneSince = nil
        isStale = false
    }

    public mutating func sessionEnded() {
        active = false
        interactive = false
        sawOverlay = false
        goneSince = nil
        isStale = false
    }

    /// Feed an observation; returns true exactly once, when the session turns stale.
    public mutating func observe(overlayVisible: Bool, at t: TimeInterval) -> Bool {
        guard isWatching else { return false }
        if overlayVisible {
            sawOverlay = true
            goneSince = nil
            return false
        }
        guard sawOverlay else { return false }
        let since = goneSince ?? t
        goneSince = since
        if t - since >= goneGrace {
            isStale = true
            return true
        }
        return false
    }
}
