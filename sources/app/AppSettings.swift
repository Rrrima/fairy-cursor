import AppKit
import Combine

/// The user's choices about where things go. Stored in UserDefaults; folders are kept as paths so
/// they read plainly in `defaults read`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let notesFolder = "notes.folder"
        static let screenshotsFolder = "screenshots.folder"
        static let keepScreenshots = "screenshots.keep"
    }

    /// Every note is a Markdown file in here.
    @Published var notesFolder: URL {
        didSet { defaults.set(notesFolder.path, forKey: Key.notesFolder) }
    }

    /// Where kept screenshots go.
    @Published var screenshotsFolder: URL {
        didSet { defaults.set(screenshotsFolder.path, forKey: Key.screenshotsFolder) }
    }

    /// On: every screenshot is saved as it's taken, and shaking only lets go of it.
    /// Off: nothing is saved unless you drop it somewhere; shaking throws it away.
    @Published var keepScreenshots: Bool {
        didSet { defaults.set(keepScreenshots, forKey: Key.keepScreenshots) }
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        notesFolder = defaults.string(forKey: Key.notesFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent("Documents/Fairy Notes", isDirectory: true)
        screenshotsFolder = defaults.string(forKey: Key.screenshotsFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SystemScreenshotTakeover.shared.originalScreenshotFolder
        keepScreenshots = defaults.object(forKey: Key.keepScreenshots) as? Bool ?? false
    }

    /// "~/Documents/Fairy Notes" rather than the full path.
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Ask for a folder; nil when cancelled.
    static func chooseFolder(startingAt url: URL, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        panel.prompt = prompt
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func open(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
