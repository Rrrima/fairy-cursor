import AppKit
import ApplicationServices
import CursorMonitorKit
import FairyCore

/// Reads what is under the cursor for notes: whether a spot is empty background, and where a
/// note made there comes from (Desktop, app window, web page).
enum NoteContext {
    /// Roles that are page/window background rather than content or a control. Static text is
    /// left out on purpose: the margin of a page is empty, a paragraph is not.
    private static let backgroundRoles: Set<String> = [
        "AXWebArea", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXLayoutArea", "AXWindow",
    ]

    /// Is the point (global CG coordinates) on empty background? `previous` is returned when the
    /// hit lands on our own windows, which say nothing about what lies beneath.
    static func isEmptySpot(at point: CGPoint, previous: Bool) -> Bool {
        let hit = axElementAtPoint(point)
        guard let element = hit.element else {
            // Nothing accessible here: bare wallpaper, or an app that keeps its tree off until an
            // assistive client asks (Acrobat, some Electron apps). Ask it for next time and allow
            // the note meanwhile; a page you can't read is more likely margin than a control.
            if let window = windowAtPoint(point, excludingPIDs: [getpid()]) {
                PasteTarget.enableWebAccessibilityIfNeeded(pid: window.pid)
            }
            return true
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == getpid() { return previous }
        if hit.isEditableText { return false }
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == FinderTarget.finderBundleID {
            // Window background counts as empty here (a note is harmless), unlike for saving.
            return FinderDropPolicy.isDropSpot(role: hit.role) || hit.role == "AXWindow"
        }
        return backgroundRoles.contains(hit.role ?? "")
    }

    /// One-line description of what is under the point, for the note trace log.
    static func describe(at point: CGPoint) -> String {
        let hit = axElementAtPoint(point)
        var pid: pid_t = 0
        if let element = hit.element { AXUIElementGetPid(element, &pid) }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "-"
        return "role=\(hit.role ?? "nil") subrole=\(hit.subrole ?? "-") app=\(bundle) editable=\(hit.isEditableText)"
    }

    /// Origin of a note started at `point` (global CG coordinates).
    static func origin(at point: CGPoint) -> NoteOrigin {
        let hit = axElementAtPoint(point)
        guard let element = hit.element else {
            // Unreadable app (e.g. Acrobat): still name the window's owner rather than "Desktop".
            guard let window = windowAtPoint(point, excludingPIDs: [getpid()]) else { return .desktop }
            let app = NSRunningApplication(processIdentifier: window.pid)
            if app?.bundleIdentifier == FinderTarget.finderBundleID, window.title.isEmpty { return .desktop }
            return NoteOrigin(kind: .app, appName: app?.localizedName ?? window.ownerName,
                              bundleID: app?.bundleIdentifier ?? window.bundleId,
                              windowTitle: window.title.isEmpty ? nil : window.title)
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        let window = axWindow(of: element)
        // Finder's desktop is either outside any window or in an untitled full-screen one; real
        // Finder windows are always titled with their folder.
        if app?.bundleIdentifier == FinderTarget.finderBundleID,
           window.flatMap({ axStringAttribute($0, kAXTitleAttribute) })?.isEmpty ?? true { return .desktop }
        return origin(element: element, window: window, app: app)
    }

    /// Origin for a note made from the menu: the frontmost app's focused window.
    static func frontmostOrigin() -> NoteOrigin {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return .desktop }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        var windowRef: AnyObject?
        let window: AXUIElement? = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success
            ? (windowRef as! AXUIElement) : nil
        if app.bundleIdentifier == FinderTarget.finderBundleID, window == nil { return .desktop }
        return origin(element: nil, window: window, app: app)
    }

    private static func origin(element: AXUIElement?, window: AXUIElement?, app: NSRunningApplication?) -> NoteOrigin {
        var origin = NoteOrigin(
            kind: .app,
            appName: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            windowTitle: window.flatMap { axStringAttribute($0, kAXTitleAttribute) }
        )
        if let element = element, let url = webURL(containing: element) {
            origin.kind = .web
            origin.url = url
        } else if let bundle = app?.bundleIdentifier, let url = scriptedBrowserURL(bundle: bundle) {
            origin.kind = .web
            origin.url = url
        } else if let window = window, let document = axStringAttribute(window, kAXDocumentAttribute), !document.isEmpty {
            origin.url = document
        }
        return origin
    }

    /// The page URL from the outermost web area above `element` (inner ones are iframes).
    /// Works for Safari, and for Chromium/Electron once PasteTarget has switched on their tree.
    private static func webURL(containing element: AXUIElement) -> String? {
        var current = element
        var found: String?
        for _ in 0..<60 {
            if axStringAttribute(current, kAXRoleAttribute) == "AXWebArea" {
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(current, kAXURLAttribute as CFString, &value) == .success,
                   let url = (value as? NSURL) as URL?, let scheme = url.scheme, ["http", "https", "file"].contains(scheme) {
                    found = url.absoluteString
                }
            }
            var parent: AnyObject?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            current = next as! AXUIElement
        }
        return found
    }

    /// Fallback when the browser's accessibility tree has no URL. Asks once for Automation.
    private static func scriptedBrowserURL(bundle: String) -> String? {
        let chromium = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
                        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium"]
        let script: String
        if bundle == "com.apple.Safari" || bundle == "com.apple.SafariTechnologyPreview" {
            script = "tell application id \"\(bundle)\" to return URL of front document"
        } else if chromium.contains(bundle) {
            script = "tell application id \"\(bundle)\" to return URL of active tab of front window"
        } else {
            return nil
        }
        guard let url = FinderTarget.runAppleScript(script), url.hasPrefix("http") || url.hasPrefix("file") else { return nil }
        return url
    }
}
