import AppKit
import ApplicationServices
import CursorMonitorKit
import FairyCore

/// Saves the held screenshot into the Finder folder (or the Desktop) the user double-clicked.
enum FinderTarget {
    static let finderBundleID = "com.apple.finder"

    /// Is a double-click on this Finder element a "put it here" gesture? (The empty background
    /// of a folder view or the desktop — not an item, not window chrome; see `FinderDropPolicy`.)
    static func isDropSpot(role: String?, element: AXUIElement?) -> Bool {
        guard FinderDropPolicy.isDropSpot(role: role) else { return false }
        let ancestors = element.map { AXNode($0).ancestorRoles() } ?? []
        return FinderDropPolicy.isDropSpot(role: role, ancestorRoles: ancestors)
    }

    /// Resolve the folder for a double-click on `element` (nil for the desktop background).
    static func folder(for element: AXUIElement?) -> URL? {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        guard let element = element, axWindow(of: element) != nil else {
            // Finder's desktop icon view lives directly under the application element.
            return desktop
        }
        // The double-click made that window (or the desktop) Finder's insertion location.
        for script in [
            "tell application \"Finder\" to POSIX path of (insertion location as alias)",
            "tell application \"Finder\" to POSIX path of (target of front Finder window as alias)",
        ] {
            if let path = runAppleScript(script) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
        }
        return desktop
    }

    /// Write the screenshot as PNG, named like macOS does, never overwriting.
    static func save(_ screenshot: HeldScreenshot, into folder: URL) -> URL? {
        guard let data = screenshot.pngData() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let base = "Screenshot \(formatter.string(from: screenshot.capturedAt))"
        var url = folder.appendingPathComponent("\(base).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).png")
            n += 1
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("[FairyCursor] save failed: \(error)")
            return nil
        }
    }

    static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error = error {
            NSLog("[FairyCursor] AppleScript error: \(error)")
            return nil
        }
        let value = result.stringValue
        return (value?.isEmpty ?? true) ? nil : value
    }
}
