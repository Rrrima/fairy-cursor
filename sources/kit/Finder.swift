import AppKit

/// Talking to Finder, shared by dropping into a Finder window and noting where a note was started.
public enum Finder {
    public static let bundleID = "com.apple.finder"

    /// Run AppleScript and return its string result (nil on error or an empty result).
    public static func runAppleScript(_ source: String) -> String? {
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
