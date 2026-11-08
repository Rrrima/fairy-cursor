import AppKit
import SwiftUI

/// Owns the note panels: creating, restoring, putting away, deleting, and the menu section.
@MainActor
final class NotesController: NSObject {
    let store = NoteStore()
    private var open: [UUID: (panel: NotePanel, model: NoteModel)] = [:]
    private var observers: [UUID: [NSObjectProtocol]] = [:]
    /// Notes listed directly in the menu; the rest go in a submenu.
    private let inlineMenuCount = 6
    /// What the fairy is carrying, top card first (empty when its hands are free).
    var carriedScreenshots: () -> [HeldScreenshot] = { [] }
    /// These carried screenshots went into a note; the fairy should let go of (only) them.
    var onScreenshotsTaken: ([UUID]) -> Void = { _ in }

    /// Reopen the notes that were on screen when the app last quit.
    func restore() {
        for note in store.recent.reversed() where note.isOpen {
            show(note, growsIn: false, focus: false)
        }
    }

    func flush() { store.flush() }

    /// A note grown out of the summon pill at `mouse` (AppKit coordinates).
    func create(at mouse: CGPoint, origin: NoteOrigin) {
        let size = NoteLayout.noteSize
        let inset = NoteLayout.inset
        // The card's top-left starts where the pill's was, so it grows out of it.
        let cardTopLeft = CGPoint(x: mouse.x - NoteLayout.summonSize.width / 2, y: mouse.y + NoteLayout.summonSize.height / 2)
        var frame = NSRect(
            x: cardTopLeft.x - inset,
            y: cardTopLeft.y + inset - (size.height + inset * 2),
            width: size.width + inset * 2,
            height: size.height + inset * 2
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame.insetBy(dx: -inset, dy: -inset)
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        }
        let now = Date()
        let note = Note(id: UUID(), text: "", createdAt: now, updatedAt: now, origin: origin, frame: frame, isOpen: true)
        NoteLog.write("note created from \(origin.kind.rawValue) (\(origin.label)) frame=\(frame)")
        store.insert(note)
        show(note, growsIn: true, focus: true)
    }

    /// Save what the fairy carries into Notes/attachments and return Markdown for it.
    private func attachCarriedScreenshots() -> String? {
        let shots = carriedScreenshots()
        guard !shots.isEmpty else { return nil }
        let folder = store.folder.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var taken: [UUID] = []
        let lines: [String] = shots.compactMap { shot in
            let name = "shot-\(UUID().uuidString.prefix(8).lowercased()).png"
            guard let data = shot.pngData(), (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
            taken.append(shot.id)
            return "![screenshot](attachments/\(name))"
        }
        guard !lines.isEmpty else { return nil }
        onScreenshotsTaken(taken)
        return lines.joined(separator: "\n")
    }

    func containsPoint(_ point: CGPoint) -> Bool {
        open.values.contains { $0.panel.isVisible && $0.panel.frame.insetBy(dx: NoteLayout.inset, dy: NoteLayout.inset).contains(point) }
    }

    // MARK: - Panels

    private func show(_ note: Note, growsIn: Bool, focus: Bool) {
        if let existing = open[note.id] {
            existing.panel.orderFrontRegardless()
            if focus { existing.panel.makeKey() }
            return
        }
        let id = note.id
        let panel = NotePanel(noteID: id, frame: note.frame)
        let model = NoteModel(note: note, growsIn: growsIn, focusOnOpen: focus)
        model.onChange = { [weak self] changed in
            self?.store.update(id) {
                $0.text = changed.text
                $0.updatedAt = changed.updatedAt
            }
        }
        let view = NoteView(
            model: model,
            onClose: { [weak self] in self?.putAway(id) },
            onDelete: { [weak self] in self?.delete(id) },
            onOpenOrigin: { [weak self] in self?.openOrigin(id) },
            attachmentsBase: store.folder,
            onDoubleClick: { [weak self] in self?.attachCarriedScreenshots() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting

        let saveFrame: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, let frame = self.open[id]?.panel.frame else { return }
                self.store.update(id) { $0.frame = frame }
            }
        }
        let center = NotificationCenter.default
        observers[id] = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main, using: saveFrame),
            center.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main, using: saveFrame),
        ]

        open[id] = (panel, model)
        if !note.isOpen { store.update(id) { $0.isOpen = true } }
        panel.orderFrontRegardless()
        if focus { panel.makeKey() }
    }

    private func closePanel(_ id: UUID) {
        guard let entry = open.removeValue(forKey: id) else { return }
        observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        entry.panel.orderOut(nil)
    }

    /// Take the note off screen; it stays in the menu. Empty notes are simply discarded.
    func putAway(_ id: UUID) {
        closePanel(id)
        if store.notes[id]?.isBlank ?? true {
            store.delete(id)
        } else {
            store.update(id) { $0.isOpen = false }
        }
    }

    func delete(_ id: UUID) {
        closePanel(id)
        store.delete(id)
    }

    func openOrigin(_ id: UUID) {
        guard let origin = store.notes[id]?.origin else { return }
        let workspace = NSWorkspace.shared
        let appURL = origin.bundleID.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        switch origin.kind {
        case .desktop:
            workspace.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true))
        case .web:
            guard let url = origin.url.flatMap({ URL(string: $0) }) else { return }
            // Back in the browser it was written in, not whatever the default is.
            if let appURL = appURL {
                workspace.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open(url)
            }
        case .app:
            guard let appURL = appURL else { return }
            if let document = origin.url.flatMap({ URL(string: $0) }), document.isFileURL {
                workspace.open([document], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    static func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - Menu

    /// The notes section of the status menu. Holding ⌥ turns each note into "Delete …".
    func appendMenuItems(to menu: NSMenu, summonToggle: NSMenuItem) {
        let notes = store.recent
        menu.addItem(.sectionHeader(title: notes.isEmpty ? "Notes" : "Notes (\(notes.count))"))
        if notes.isEmpty {
            let empty = NSMenuItem(title: "Hold ⌥ on empty space, then click", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for note in notes.prefix(inlineMenuCount) { addItems(for: note, to: menu) }
        if notes.count > inlineMenuCount {
            let more = NSMenuItem(title: "Older Notes", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for note in notes.dropFirst(inlineMenuCount) { addItems(for: note, to: submenu) }
            more.submenu = submenu
            menu.addItem(more)
        }

        menu.addItem(item("New Note", #selector(newNote), key: "n"))
        let anyOpen = notes.contains { $0.isOpen }
        let anyAway = notes.contains { !$0.isOpen }
        if anyAway { menu.addItem(item("Show All Notes", #selector(showAll))) }
        if anyOpen { menu.addItem(item("Put Away All Notes", #selector(putAwayAll))) }
        menu.addItem(item("Show Notes Folder", #selector(revealFolder)))
        menu.addItem(summonToggle)
    }

    private func addItems(for note: Note, to menu: NSMenu) {
        let open = item(note.title, #selector(openNote(_:)))
        open.representedObject = note.id
        open.subtitle = "\(note.origin.label) · \(note.updatedAt.formatted(.relative(presentation: .named)))"
        open.toolTip = note.origin.detail
        open.state = note.isOpen ? .on : .off
        if let icon = note.origin.kind == .desktop ? NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            : Self.appIcon(bundleID: note.origin.bundleID) {
            icon.size = NSSize(width: 16, height: 16)
            open.image = icon
        }
        menu.addItem(open)

        let delete = item("Delete “\(note.title)”", #selector(deleteNote(_:)))
        delete.representedObject = note.id
        delete.keyEquivalentModifierMask = .option
        delete.isAlternate = true
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(delete)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let note = store.notes[id] else { return }
        show(note, growsIn: false, focus: true)
    }

    @objc private func deleteNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        delete(id)
    }

    @objc private func newNote() {
        let origin = NoteContext.frontmostOrigin()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let center = screen.map { CGPoint(x: $0.visibleFrame.midX - NoteLayout.noteSize.width / 2, y: $0.visibleFrame.midY + NoteLayout.noteSize.height / 2) } ?? mouse
        create(at: center, origin: origin)
    }

    @objc private func showAll() {
        for note in store.recent.reversed() { show(note, growsIn: false, focus: false) }
    }

    @objc private func putAwayAll() {
        for id in Array(open.keys) { putAway(id) }
    }

    @objc private func revealFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.folder])
    }
}
