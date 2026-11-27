import AppKit
import Sparkle

/// Keeps the app current. Sparkle reads the feed on the website about once a day (and whenever
/// "Check for Updates…" is pressed), shows what's new, and on "Install Update" downloads the new
/// version, checks it was signed with our key, swaps the app and starts it again.
///
/// The fairy lives in the menu bar, so an update found in the background must not throw a window
/// in front of whatever the user is doing: it waits as a dot on the menu bar mark and a line at
/// the top of the menu.
@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    /// The version that's waiting to be installed, once a background check has found one.
    @Published private(set) var waiting: String?
    /// Whether the feed is looked at without being asked.
    @Published var checksAutomatically = true {
        didSet {
            guard let updater = controller?.updater, updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    private var controller: SPUStandardUpdaterController?

    /// "0.5.0"
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// False for a bare `swift run` binary, which has no feed to read and nothing to replace.
    var isAvailable: Bool { controller != nil }

    func start() {
        guard controller == nil, Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
    }

    /// Look now and say what was found, in front. Also how a waiting update is brought forward.
    func check() {
        guard let controller = controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

extension Updates: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows its own window only when that wouldn't interrupt (the app was just opened,
    /// or is already in front). Otherwise the update waits in the menu.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        Task { @MainActor in self.waiting = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.waiting = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.waiting = nil }
    }
}
