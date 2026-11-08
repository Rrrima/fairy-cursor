import AppKit
import Foundation

/// Makes the fairy the only visible result of a screenshot: no floating thumbnail in the corner
/// and no file on the Desktop. macOS keeps writing the file, but into a private folder the fairy
/// purges. The original settings are remembered and put back when the takeover is turned off or
/// the app quits.
@MainActor
final class SystemScreenshotTakeover {
    static let shared = SystemScreenshotTakeover()

    private let domain = "com.apple.screencapture" as CFString
    private let defaults = UserDefaults.standard
    private let enabledKey = "takeover.enabled"
    private let savedKey = "takeover.saved"          // marker: originals captured
    private let originalLocationKey = "takeover.originalLocation"
    private let originalThumbnailKey = "takeover.originalShowThumbnail"

    let capturesFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Fairy Cursor/Captures", isDirectory: true)
    }()

    /// Default on: the point of the fairy is to replace the corner thumbnail + auto-save.
    var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Apply the current preference (called at launch).
    func applyAtLaunch() {
        if isEnabled { activate() } else { restore() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        enabled ? activate() : restore()
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
        guard isEnabled || seconds == 0 else { return }
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
