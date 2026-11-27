import AppKit
import Combine
import FairyCore
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

    /// How the held pile travels after the cursor.
    @Published var followStyle: FollowStyle {
        didSet { defaults.set(followStyle.rawValue, forKey: followStyleKey) }
    }
    private let followStyleKey = "follow.style"

    private init() {
        followStyle = defaults.string(forKey: followStyleKey).flatMap(FollowStyle.init(rawValue:)) ?? .calm
        capturesFolder = defaults.string(forKey: capturesFolderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SystemScreenshotLocation.original
    }
}
