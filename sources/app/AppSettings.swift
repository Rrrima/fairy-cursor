import AppKit
import Combine
import FairyKit

/// The fairy's own settings (each capability keeps its own). Stored in UserDefaults; folders are
/// kept as paths so they read plainly in `defaults read`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    // The key predates recordings, when only screenshots were kept.
    private let capturesFolderKey = "screenshots.folder"

    /// Where kept screenshots and screen recordings go.
    @Published var capturesFolder: URL {
        didSet { defaults.set(capturesFolder.path, forKey: capturesFolderKey) }
    }

    private init() {
        capturesFolder = defaults.string(forKey: capturesFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SystemScreenshotLocation.original
    }
}
