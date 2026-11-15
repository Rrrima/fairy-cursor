import Foundation

/// Where macOS saves screenshots, as the user set it before the fairy's screenshot capability
/// redirected them (see `SystemScreenshotTakeover` in that capability). The default home for
/// everything the fairy keeps: screenshots and screen recordings.
public enum SystemScreenshotLocation {
    /// Keys the takeover stores the user's original settings under (in the app's defaults).
    public static let savedKey = "takeover.saved"
    public static let originalLocationKey = "takeover.originalLocation"

    /// The private folder macOS writes into while the takeover is on.
    public static let privateFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Fairy Cursor/Captures", isDirectory: true)
    }()

    /// The Desktop unless the user had changed it.
    public static var original: URL {
        let defaults = UserDefaults.standard
        let stored = defaults.bool(forKey: savedKey)
            ? defaults.string(forKey: originalLocationKey)
            : CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String
        if let path = stored.map({ NSString(string: $0).expandingTildeInPath }), path != privateFolder.path {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}
