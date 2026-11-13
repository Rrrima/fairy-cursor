import AppKit
import Foundation

/// Makes the fairy the only visible result of a screenshot: no floating thumbnail in the corner
/// and no file on the Desktop. macOS keeps writing the file, but into a private folder the fairy
/// purges. The original settings are remembered and put back when the app quits.
@MainActor
final class SystemScreenshotTakeover {
    static let shared = SystemScreenshotTakeover()

    private let domain = "com.apple.screencapture" as CFString
    private let defaults = UserDefaults.standard
    private let savedKey = "takeover.saved"          // marker: originals captured
    private let originalLocationKey = "takeover.originalLocation"
    private let originalThumbnailKey = "takeover.originalShowThumbnail"

    let capturesFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Fairy Cursor/Captures", isDirectory: true)
    }()

    /// Where macOS saved screenshots before the fairy took over (the Desktop unless the user had
    /// changed it). The default home for kept screenshots.
    var originalScreenshotFolder: URL {
        let stored = defaults.bool(forKey: savedKey) ? defaults.string(forKey: originalLocationKey) : read("location") as? String
        if let path = stored.map({ NSString(string: $0).expandingTildeInPath }), path != capturesFolder.path {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Always on while the app runs: the fairy replaces the corner thumbnail and macOS's own file
    /// (whether screenshots are kept is the fairy's call, see `AppSettings.keepScreenshots`).
    func applyAtLaunch() {
        defaults.removeObject(forKey: "takeover.enabled")   // the old on/off switch
        activate()
    }

    private func activate() {
        try? FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        if !defaults.bool(forKey: savedKey) {
            // Remember what the user had so it can be restored exactly (absent keys stay absent).
            defaults.set(read("location"), forKey: originalLocationKey)
            defaults.set(read("show-thumbnail"), forKey: originalThumbnailKey)
            defaults.set(true, forKey: savedKey)
        }
        write("location", capturesFolder.path as CFString)
        write("show-thumbnail", kCFBooleanFalse)
        purge(olderThan: 0)
    }

    func restore() {
        guard defaults.bool(forKey: savedKey) else { return }
        write("location", defaults.object(forKey: originalLocationKey) as CFPropertyList?)
        write("show-thumbnail", defaults.object(forKey: originalThumbnailKey) as CFPropertyList?)
        defaults.removeObject(forKey: savedKey)
        defaults.removeObject(forKey: originalLocationKey)
        defaults.removeObject(forKey: originalThumbnailKey)
        purge(olderThan: 0)
    }

    /// Delete the files macOS wrote into the private folder (it writes them within ~0.5 s of a
    /// capture once the thumbnail is off, so a short delay after each session is enough).
    func purge(olderThan seconds: TimeInterval) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: capturesFolder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in items {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) >= seconds { try? fm.removeItem(at: url) }
        }
    }

    private func read(_ key: String) -> Any? {
        return CFPreferencesCopyAppValue(key as CFString, domain)
    }

    private func write(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetAppValue(key as CFString, value, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
