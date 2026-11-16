import AppKit
import FairyKit
import SwiftUI

/// Hold ⌥ on empty space and click: a note grows out of the cursor, remembering where it was
/// started. Notes are Markdown files in a folder you pick; double-click one while the fairy
/// carries screenshots to drop them in.
@MainActor
public final class NotesCapability: Capability {
    public static let manifest = CapabilityManifest(
        id: "fairy.notes",
        name: "Notes",
        summary: "Hold ⌥ on empty space and click for a note.",
        permissions: [.accessibility],
        shortcuts: ["hold ⌥"]
    )

    private weak var host: FairyHost?
    private var notes: NotesController?
    private var summoner: NoteSummoner?
    private let settings = NotesSettings.shared
    private var id: String { Self.manifest.id }

    public init() {}

    public func activate(host: FairyHost) {
        self.host = host
        let notes = NotesController()
        notes.carriedScreenshots = { [weak self] in self?.host?.carried ?? [] }
        notes.onScreenshotsTaken = { [weak self] ids in
            self?.host?.delivered(ids, hint: ids.count == 1 ? "added to note" : "added \(ids.count) to note")
        }
        notes.restore()
        // A note takes the pile itself (through its own double-click), so the fairy leaves
        // double-clicks over notes alone and says what one would do.
        host.setDropZone(DropZone(hint: "double-click to add to note") { [weak notes] point in
            notes?.containsPoint(point) ?? false
        }, owner: id)

        let summoner = NoteSummoner()
        summoner.isBlocked = { [weak self] in self?.host?.isScreenBusy ?? true }
        summoner.isOverOwnWindow = { [weak notes] point in notes?.containsPoint(point) ?? false }
        summoner.onSummon = { [weak notes] mouse, origin in
            FairyLog.write("note from \(origin.kind.rawValue): \(origin.label)")
            notes?.create(at: mouse, origin: origin)
        }
        summoner.start()

        self.notes = notes
        self.summoner = summoner
    }

    public func deactivate() {
        summoner?.stop()
        summoner = nil
        notes?.hideAll()
        notes = nil
        host?.setDropZone(nil, owner: id)
        host = nil
    }

    public func menuItems() -> [NSMenuItem] {
        guard let notes = notes else { return [] }
        notes.refreshFromDisk()
        let menu = NSMenu()
        notes.appendMenuItems(to: menu)
        let items = menu.items
        menu.removeAllItems()
        return items
    }

    public func settingsView() -> AnyView? {
        AnyView(NotesSettingsRows(settings: settings, folderChanged: { [weak self] url in
            self?.notes?.switchFolder(to: url)
        }))
    }
}

/// Where notes live and whether ⌥ summons one. Stored in UserDefaults under the keys they always had.
@MainActor
final class NotesSettings: ObservableObject {
    static let shared = NotesSettings()
    private let defaults = UserDefaults.standard

    /// Every note is a Markdown file in here.
    @Published var folder: URL {
        didSet { defaults.set(folder.path, forKey: "notes.folder") }
    }

    @Published var summonEnabled: Bool {
        didSet { defaults.set(summonEnabled, forKey: "noteSummonEnabled") }
    }

    private init() {
        folder = defaults.string(forKey: "notes.folder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Fairy Notes", isDirectory: true)
        summonEnabled = defaults.object(forKey: "noteSummonEnabled") as? Bool ?? true
    }
}

private struct NotesSettingsRows: View {
    @ObservedObject var settings: NotesSettings
    let folderChanged: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FolderRow(
                title: "Notes folder",
                folder: settings.folder,
                detail: "Each note is a Markdown file you can open anywhere.",
                choose: {
                    guard let url = Folders.choose(startingAt: settings.folder, prompt: "Use for notes") else { return }
                    settings.folder = url
                    folderChanged(url)
                }
            )
            ToggleRow(title: "Hold ⌥ on empty space for a note", isOn: $settings.summonEnabled)
        }
    }
}
