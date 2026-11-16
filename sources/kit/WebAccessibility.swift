import AppKit
@preconcurrency import ApplicationServices

/// Turns on the web accessibility tree of Chromium-based browsers and Electron apps, which they
/// build only once an assistive client announces itself. Shared because both pasting into a web
/// page and reading where a note was started need it.
@MainActor
public enum WebAccessibility {
    /// Chromium-based browsers and Electron apps only build their web accessibility tree once an
    /// assistive client announces itself. Without it, inputs inside web pages are invisible to
    /// hit-testing, so we turn it on for the app under the cursor (once per app).
    nonisolated(unsafe) private static var axEnabledPIDs: Set<pid_t> = []
    nonisolated private static let axEnabledLock = NSLock()

    public nonisolated static func enableWebAccessibilityIfNeeded(pid: pid_t) {
        let isNew = axEnabledLock.withLock { axEnabledPIDs.insert(pid).inserted }
        guard isNew else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
        }
    }

    /// Flip the switch for every Chromium-like app that is already running (and call again from
    /// a launch observer for new ones). Chrome takes ~2 s to build its tree, so this has to happen
    /// well before the first double-click.
    public static func prepareRunningApps() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if isChromiumLike(app) { enableWebAccessibilityIfNeeded(pid: app.processIdentifier) }
        }
    }

    public nonisolated static func isChromiumLike(_ app: NSRunningApplication) -> Bool {
        let bundle = app.bundleIdentifier ?? ""
        let chromiumPrefixes = ["com.google.Chrome", "com.brave.", "com.microsoft.edgemac", "company.thebrowser",
                                "com.vivaldi", "org.chromium", "com.operasoftware"]
        if chromiumPrefixes.contains(where: { bundle.hasPrefix($0) }) { return true }
        // Electron / CEF apps ship the framework inside the bundle.
        guard let url = app.bundleURL else { return false }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) {
            return names.contains { $0.hasPrefix("Electron Framework") || $0.hasPrefix("Chromium Embedded Framework") }
        }
        return false
    }
}
