import AppKit
import FairyKit
import SwiftUI

/// Owns the note panels: creating, restoring, putting away, deleting, and the menu section.
@MainActor
final class NotesController: NSObject {
    let store = NoteStore(folder: NotesSettings.shared.folder)
    private var open: [UUID: (panel: NotePanel, model: NoteModel)] = [:]
    private var observers: [UUID: [NSObjectProtocol]] = [:]
    private var notesList: (ownerID: UUID?, panel: NotePanel)?
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

    /// Take the notes and list off screen but remember which notes were up, so they come back next time
    /// (the capability is being switched off, or the app is quitting).
    func hideAll() {
        closeNotesList()
        for id in Array(open.keys) {
            store.update(id) { $0.isOpen = true }
            closePanel(id)
        }
        store.flush()
    }

    /// The notes folder changed: put this folder's notes away (they stay where they are on disk)
    /// and bring up the ones that were open from the new folder.
    func switchFolder(to folder: URL) {
        guard folder != store.folder else { return }
        hideAll()
        store.switchFolder(to: folder)
        restore()
    }

    /// Pick up files added, edited or removed in Finder (called when the menu opens).
    func refreshFromDisk() {
        store.refresh(keeping: Set(open.keys))
    }

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
            if let movie = shot.movie {
                // A recording: copy the video next to the note and link it.
                let name = "recording-\(UUID().uuidString.prefix(8).lowercased()).\(movie.pathExtension)"
                guard (try? FileManager.default.copyItem(at: movie, to: folder.appendingPathComponent(name))) != nil else { return nil }
                taken.append(shot.id)
                return "[recording](attachments/\(name))"
            }
            let name = "shot-\(UUID().uuidString.prefix(8).lowercased()).png"
            guard let data = shot.pngData(), (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil else { return nil }
            taken.append(shot.id)
            return "![screenshot](attachments/\(name))"
        }
        guard !lines.isEmpty else { return nil }
        onScreenshotsTaken(taken)
        return lines.joined(separator: "\n")
    }

    func containsNote(at point: CGPoint) -> Bool {
        guard !containsNotesList(at: point) else { return false }
        return open.values.contains { $0.panel.isVisible && $0.panel.frame.insetBy(dx: NoteLayout.inset, dy: NoteLayout.inset).contains(point) }
    }

    func containsOwnWindow(at point: CGPoint) -> Bool {
        containsNotesList(at: point) || containsNote(at: point)
    }

    private func containsNotesList(at point: CGPoint) -> Bool {
        guard let panel = notesList?.panel else { return false }
        return panel.isVisible && panel.frame.contains(point)
    }

    // MARK: - Panels

    private func show(_ note: Note, growsIn: Bool, focus: Bool) {
        if let existing = open[note.id] {
            existing.panel.orderFrontRegardless()
            if focus { existing.panel.makeKey() }
            return
        }
        let id = note.id
        let panel = NotePanel(frame: note.frame)
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
            onToggleNotesList: { [weak self] in self?.toggleNotesList(for: id) },
            attachmentsBase: store.folder,
            onDoubleClick: { [weak self] in self?.attachCarriedScreenshots() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting

        let saveFrame: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, let panel = self.open[id]?.panel else { return }
                self.store.update(id) { $0.frame = panel.frame }
                if let list = self.notesList, list.ownerID == id {
                    let frame = self.notesListFrame(beside: panel)
                    if list.panel.frame != frame { list.panel.setFrame(frame, display: true) }
                }
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
        if let list = notesList, list.ownerID == id {
            entry.panel.removeChildWindow(list.panel)
            notesList?.ownerID = nil
            (list.panel.contentView as? NSHostingView<NoteListView>)?.rootView.ownerID = nil
            list.panel.orderFrontRegardless()
        }
        observers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        entry.panel.orderOut(nil)
    }

    private func toggleNotesList(for id: UUID) {
        let wasOpen = notesList?.ownerID == id
        closeNotesList()
        guard !wasOpen, let owner = open[id] else { return }

        refreshFromDisk()
        let panel = NotePanel(frame: notesListFrame(beside: owner.panel))
        panel.title = "Notes"
        panel.hasShadow = true
        let hosting = NSHostingView(rootView: NoteListView(
            store: store,
            ownerID: id,
            onSelect: { [weak self] in self?.openNote(id: $0) },
            onClose: { [weak self] in self?.closeNotesList() }
        ))
        hosting.sizingOptions = []
        panel.contentView = hosting
        notesList = (id, panel)
        owner.model.isNotesListOpen = true
        owner.panel.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
    }

    private func closeNotesList() {
        guard let list = notesList else { return }
        notesList = nil
        if let ownerID = list.ownerID, let owner = open[ownerID] {
            owner.panel.removeChildWindow(list.panel)
            owner.model.isNotesListOpen = false
        }
        list.panel.orderOut(nil)
    }

    private func notesListFrame(beside panel: NotePanel) -> NSRect {
        let card = panel.frame.insetBy(dx: NoteLayout.inset, dy: NoteLayout.inset)
        let screen = panel.screen ?? NSScreen.main
        return NoteListLayout.frame(beside: card, within: screen?.visibleFrame)
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
    /// "Recent Notes" (the list opens as a submenu on hover) and "Open Notes Folder".
    func appendMenuItems(to menu: NSMenu) {
        let notes = store.recent
        let recent = NSMenuItem(title: "Recent Notes", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if notes.isEmpty {
            let empty = NSMenuItem(title: "No notes yet — hold ⌥ on empty space", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for note in notes { addItems(for: note, to: submenu) }
        recent.submenu = submenu
        menu.addItem(recent)
        menu.addItem(item("Open Notes Folder", #selector(openFolder)))
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

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        openNote(id: id)
    }

    private func openNote(id: UUID) {
        guard let note = store.notes[id] else { return }
        show(note, growsIn: false, focus: true)
    }

    @objc private func deleteNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        delete(id)
    }

    @objc private func openFolder() {
        Folders.open(store.folder)
    }
}
