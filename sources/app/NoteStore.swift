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

    /// File name (without ".md") for the note: its first line, made safe for Finder.
    var fileStem: String {
        guard !isBlank else { return "Untitled" }
        var stem = title.replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: #"[/\\\n\r\t]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        while stem.hasPrefix(".") { stem.removeFirst() }
        return stem.isEmpty ? "Untitled" : stem
    }
}


/// Notes as plain Markdown files in a folder the user picks (`AppSettings.notesFolder`), so they
/// open in any editor and sync like any other file. Each file starts with a short front matter
/// block (id, when, and where it was written); where the note's window sits on screen is app
/// state, kept in Application Support so the files stay clean.
///
/// The file is named after the note's first line and renamed as that changes. A blank note has
/// no file until something is typed in it.
@MainActor
final class NoteStore {
    private(set) var notes: [UUID: Note] = [:]
    private(set) var folder: URL
    /// The file each note was last written to (absent for a blank note).
    private var files: [UUID: URL] = [:]
    private var pending: [UUID: DispatchWorkItem] = [:]
    private var windows: [UUID: WindowState] = [:]

    struct WindowState: Codable {
        var frame: CGRect
        var isOpen: Bool
    }

    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Fairy Cursor", isDirectory: true)
    private let windowsFile = NoteStore.support.appendingPathComponent("note-windows.json")

    init(folder: URL) {
        self.folder = folder
        if let data = try? Data(contentsOf: windowsFile),
           let saved = try? JSONDecoder().decode([UUID: WindowState].self, from: data) {
            windows = saved
        }
        prepareFolder()
        migrateLegacyNotes()
        reload()
    }

    /// Most recently edited first.
    var recent: [Note] { notes.values.sorted { $0.updatedAt > $1.updatedAt } }

    /// Point at another folder: save what's pending here, then read the notes there.
    func switchFolder(to newFolder: URL) {
        flush()
        folder = newFolder
        prepareFolder()
        notes = [:]
        files = [:]
        reload()
    }

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

    /// Remove the note; its file goes to the Trash, so a mistake can be undone in Finder.
    func delete(_ id: UUID) {
        pending.removeValue(forKey: id)?.cancel()
        notes.removeValue(forKey: id)
        windows.removeValue(forKey: id)
        if let file = files.removeValue(forKey: id) {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        saveWindows()
    }

    /// Write everything still waiting (on quit).
    func flush() {
        for id in Array(pending.keys) {
            pending.removeValue(forKey: id)?.cancel()
            write(id)
        }
    }

    /// Pick up edits, new files and deletions made outside the app. Notes in `keeping` (open on
    /// screen) are left as they are in memory: the app's copy is the live one.
    func refresh(keeping open: Set<UUID>) {
        let onDisk = readFolder()
        var seen = Set<UUID>()
        for (note, url) in onDisk {
            seen.insert(note.id)
            guard !open.contains(note.id), pending[note.id] == nil else { continue }
            notes[note.id] = note
            files[note.id] = url
        }
        for id in Array(notes.keys) where !seen.contains(id) && !open.contains(id) && pending[id] == nil {
            notes.removeValue(forKey: id)
            files.removeValue(forKey: id)
        }
    }

    // MARK: - Files

    private func prepareFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func reload() {
        for (note, url) in readFolder() {
            notes[note.id] = note
            files[note.id] = url
        }
    }

    /// Every .md file in the folder (not subfolders), parsed. Files without our front matter get
    /// a fresh id; it's written into the file the first time the note changes.
    private func readFolder() -> [(Note, URL)] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey], options: [.skipsHiddenFiles])) ?? []
        var result: [(Note, URL)] = []
        var ids = Set<UUID>()
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            var (meta, body) = NoteFile.parse(text)
            // A file copied in Finder keeps its twin's id; give the copy its own.
            if let id = meta.id, ids.contains(id) { meta.id = nil }
            // Reuse the id we gave this file earlier in the session, if any.
            let id = meta.id ?? files.first(where: { $0.value == url })?.key ?? UUID()
            ids.insert(id)
            let window = windows[id]
            let note = Note(
                id: id,
                text: body,
                createdAt: meta.created ?? values?.creationDate ?? Date(),
                updatedAt: values?.contentModificationDate ?? Date(),
                origin: meta.origin,
                frame: window?.frame ?? Self.defaultFrame(),
                isOpen: window?.isOpen ?? false
            )
            result.append((note, url))
        }
        return result
    }

    private func write(_ id: UUID) {
        pending.removeValue(forKey: id)
        guard let note = notes[id] else { return }
        windows[id] = WindowState(frame: note.frame, isOpen: note.isOpen)
        saveWindows()
        // A blank note has no file; one that was emptied out keeps its old file until it's
        // put away (and then deleted), so clearing a note by accident loses nothing yet.
        guard !note.isBlank else { return }
        let fm = FileManager.default
        prepareFolder()
        var target = files[id] ?? uniqueFile(for: note.fileStem, excluding: nil)
        if let current = files[id], !Self.name(current.deletingPathExtension().lastPathComponent, matches: note.fileStem) {
            // The first line changed: follow it with the file name.
            let renamed = uniqueFile(for: note.fileStem, excluding: current)
            if (try? fm.moveItem(at: current, to: renamed)) != nil { target = renamed }
        }
        do {
            try NoteFile.render(note).write(to: target, atomically: true, encoding: .utf8)
            files[id] = target
        } catch {
            NSLog("[FairyCursor] note save failed: \(error)")
        }
    }

    /// Is `name` this stem, or the stem with a " 2"-style suffix `uniqueFile` added?
    private static func name(_ name: String, matches stem: String) -> Bool {
        guard name.hasPrefix(stem) else { return false }
        let rest = name.dropFirst(stem.count)
        return rest.isEmpty || (rest.first == " " && rest.dropFirst().allSatisfy(\.isNumber) && rest.count > 1)
    }

    /// "Stem.md", or "Stem 2.md", "Stem 3.md"… if taken by another file.
    private func uniqueFile(for stem: String, excluding own: URL?) -> URL {
        let fm = FileManager.default
        var n = 1
        while true {
            let name = n == 1 ? "\(stem).md" : "\(stem) \(n).md"
            let url = folder.appendingPathComponent(name)
            if url == own || !fm.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    private func saveWindows() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(windows).write(to: windowsFile, options: .atomic)
    }

    /// Where a note found in the folder appears the first time it's opened: centred on the main screen.
    private static func defaultFrame() -> CGRect {
        let size = CGSize(width: NoteLayout.noteSize.width + NoteLayout.inset * 2, height: NoteLayout.noteSize.height + NoteLayout.inset * 2)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: - Migration

    /// Earlier versions kept one JSON file per note in Application Support. Turn them into
    /// Markdown files in the notes folder once, bringing their attachments along.
    private func migrateLegacyNotes() {
        let fm = FileManager.default
        let legacy = Self.support.appendingPathComponent("Notes", isDirectory: true)
        let marker = legacy.appendingPathComponent(".migrated")
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: marker.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let jsons = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for url in jsons where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let note = try? decoder.decode(Note.self, from: data) else { continue }
            windows[note.id] = WindowState(frame: note.frame, isOpen: note.isOpen)
            guard !note.isBlank else { continue }
            let file = uniqueFile(for: note.fileStem, excluding: nil)
            try? NoteFile.render(note).write(to: file, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: note.updatedAt, .creationDate: note.createdAt], ofItemAtPath: file.path)
        }
        let oldAttachments = legacy.appendingPathComponent("attachments", isDirectory: true)
        let newAttachments = folder.appendingPathComponent("attachments", isDirectory: true)
        if let images = try? fm.contentsOfDirectory(at: oldAttachments, includingPropertiesForKeys: nil), !images.isEmpty {
            try? fm.createDirectory(at: newAttachments, withIntermediateDirectories: true)
            for image in images { try? fm.copyItem(at: image, to: newAttachments.appendingPathComponent(image.lastPathComponent)) }
        }
        saveWindows()
        fm.createFile(atPath: marker.path, contents: Data())
    }
}

/// The on-disk form of a note: a front matter block, then the Markdown as typed.
///
///     ---
///     id: 6F9A…
///     created: 2026-11-11T14:32:05Z
///     from: "github.com"
///     app: "Safari"
///     url: "https://github.com/…"
///     ---
///     the note…
///
/// Values are JSON strings (also valid YAML), so titles with colons or quotes round-trip.
enum NoteFile {
    struct Meta {
        var id: UUID?
        var created: Date?
        var origin = NoteOrigin.desktop
    }

    private static let iso = ISO8601DateFormatter()

    static func render(_ note: Note) -> String {
        let o = note.origin
        var lines = ["---", "id: \(note.id.uuidString)", "created: \(iso.string(from: note.createdAt))"]
        lines.append("from: \(quote(o.label))")
        lines.append("kind: \(o.kind.rawValue)")
        if let v = o.appName { lines.append("app: \(quote(v))") }
        if let v = o.bundleID { lines.append("bundle: \(quote(v))") }
        if let v = o.windowTitle, !v.isEmpty { lines.append("window: \(quote(v))") }
        if let v = o.url { lines.append("url: \(quote(v))") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + note.text
    }

    static func parse(_ text: String) -> (Meta, String) {
        var meta = Meta()
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return (meta, text) }
        let lines = text.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return (meta, text) }
        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        meta.id = fields["id"].flatMap(UUID.init(uuidString:))
        meta.created = fields["created"].flatMap { iso.date(from: $0) }
        meta.origin = NoteOrigin(
            kind: fields["kind"].flatMap(NoteOrigin.Kind.init(rawValue:)) ?? .desktop,
            appName: fields["app"],
            bundleID: fields["bundle"],
            windowTitle: fields["window"],
            url: fields["url"]
        )
        var body = lines[(end + 1)...].joined(separator: "\n")
        // render() puts one blank line between the block and the note.
        if body.hasPrefix("\n") { body.removeFirst() }
        return (meta, body)
    }

    private static func quote(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(s), let json = String(data: data, encoding: .utf8) else { return s }
        return json
    }

    private static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), let data = s.data(using: .utf8), let value = try? JSONDecoder().decode(String.self, from: data) else { return s }
        return value
    }
}
