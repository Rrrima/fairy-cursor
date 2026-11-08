import AppKit

/// Where a note was started: the Desktop, an app window, or a web page.
struct NoteOrigin: Codable, Equatable {
    enum Kind: String, Codable { case desktop, app, web }

    var kind: Kind
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    /// The page for `.web`; the window's document (a file URL) for `.app` when the app exposes one.
    var url: String?

    static let desktop = NoteOrigin(kind: .desktop)

    /// Short label for the note's chip and the menu: "Desktop", "Xcode", "github.com", or the file
    /// name for a local document ("paper.pdf", whether open in Preview or in a browser tab).
    var label: String {
        if let file = url.flatMap({ URL(string: $0) }), file.isFileURL, !file.lastPathComponent.isEmpty {
            return file.lastPathComponent
        }
        switch kind {
        case .desktop:
            return "Desktop"
        case .app:
            return appName ?? "App"
        case .web:
            guard var host = url.flatMap({ URL(string: $0) })?.host() else { return appName ?? "Web" }
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return host
        }
    }

    /// Longer description for tooltips.
    var detail: String {
        var parts: [String] = []
        if kind != .desktop, let appName = appName { parts.append(appName) }
        if let title = windowTitle, !title.isEmpty { parts.append(title) }
        if let url = url { parts.append(url) }
        return parts.isEmpty ? label : parts.joined(separator: "\n")
    }
}

struct Note: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date
    let origin: NoteOrigin
    /// Panel frame in AppKit screen coordinates (includes the shadow inset).
    var frame: CGRect
    /// On screen or put away (put-away notes stay listed in the menu).
    var isOpen: Bool

    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// First non-empty line without its Markdown markers.
    var title: String {
        guard let line = text.split(separator: "\n").lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return "Empty note" }
        let stripped = line
            .replacingOccurrences(of: #"^(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+|>\s*)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
        let result = stripped.isEmpty ? line : stripped
        return result.count > 48 ? String(result.prefix(47)) + "…" : result
    }
}

/// One JSON file per note in ~/Library/Application Support/Fairy Cursor/Notes, written shortly
/// after each change.
@MainActor
final class NoteStore {
    private(set) var notes: [UUID: Note] = [:]
    let folder: URL
    private var pending: [UUID: DispatchWorkItem] = [:]

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        folder = support.appendingPathComponent("Fairy Cursor/Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    /// Most recently edited first.
    var recent: [Note] { notes.values.sorted { $0.updatedAt > $1.updatedAt } }

    func insert(_ note: Note) {
        notes[note.id] = note
        write(note.id)
    }

    /// Apply a change and save it a moment later (typing and dragging produce bursts).
    func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard var note = notes[id] else { return }
        change(&note)
        notes[id] = note
        pending[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.write(id) }
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func delete(_ id: UUID) {
        pending.removeValue(forKey: id)?.cancel()
        notes.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Write everything still waiting (on quit).
    func flush() {
        for id in Array(pending.keys) {
            pending.removeValue(forKey: id)?.cancel()
            write(id)
        }
    }

    private func file(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }

    private func write(_ id: UUID) {
        pending.removeValue(forKey: id)
        guard let note = notes[id] else { return }
        do {
            try encoder.encode(note).write(to: file(for: id), options: .atomic)
        } catch {
            NSLog("[FairyCursor] note save failed: \(error)")
        }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let note = try? decoder.decode(Note.self, from: data) else { continue }
            notes[note.id] = note
        }
    }
}
