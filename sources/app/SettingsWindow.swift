import AppKit
import ServiceManagement
import SwiftUI

/// Everything the settings window can change. App-owned switches (the ⌥ summon, showing the
/// fairy when empty, launch at login) come in as closures so the window stays a plain view.
@MainActor
final class SettingsModel: ObservableObject {
    let settings = AppSettings.shared
    @Published var summonEnabled: Bool { didSet { setSummon(summonEnabled) } }
    @Published var showWhenIdle: Bool { didSet { setShowWhenIdle(showWhenIdle) } }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var accessibility = Permissions.accessibility
    @Published var screenRecording = Permissions.screenRecording

    private let setSummon: (Bool) -> Void
    private let setShowWhenIdle: (Bool) -> Void
    /// The notes folder changed (the app moves its open notes over).
    let onNotesFolderChanged: (URL) -> Void

    init(summon: Bool, setSummon: @escaping (Bool) -> Void,
         showWhenIdle: Bool, setShowWhenIdle: @escaping (Bool) -> Void,
         onNotesFolderChanged: @escaping (URL) -> Void) {
        self.summonEnabled = summon
        self.showWhenIdle = showWhenIdle
        self.setSummon = setSummon
        self.setShowWhenIdle = setShowWhenIdle
        self.onNotesFolderChanged = onNotesFolderChanged
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibility = Permissions.accessibility
        screenRecording = Permissions.screenRecording
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[FairyCursor] launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func chooseNotesFolder() {
        guard let url = AppSettings.chooseFolder(startingAt: settings.notesFolder, prompt: "Use for notes") else { return }
        settings.notesFolder = url
        onNotesFolderChanged(url)
    }

    func chooseScreenshotsFolder() {
        guard let url = AppSettings.chooseFolder(startingAt: settings.screenshotsFolder, prompt: "Use for screenshots") else { return }
        settings.screenshotsFolder = url
    }
}

/// A borderless, transparent window: the glass card SwiftUI draws is the whole window, like
/// the notes. Moves by its background, closes on Esc or its own close button; reused while open.
@MainActor
final class SettingsWindowController {
    private var window: SettingsPanel?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show() {
        model.refresh()
        if window == nil {
            let window = SettingsPanel()
            let hosting = NSHostingView(rootView: SettingsView(model: model, settings: model.settings, close: { [weak window] in
                window?.orderOut(nil)
            }))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = .clear
            // The window sets the size; the view fills whatever it's given.
            hosting.sizingOptions = []
            let frame = ResizableFrameView(inset: SettingsView.shadowInset)
            frame.embed(hosting)
            window.contentView = frame
            let pad = SettingsView.shadowInset * 2
            let visible = NSScreen.main?.visibleFrame.height ?? 900
            window.contentMinSize = NSSize(width: SettingsView.minSize.width + pad, height: SettingsView.minSize.height + pad)
            window.setContentSize(NSSize(width: SettingsView.idealSize.width + pad,
                                         height: min(SettingsView.idealSize.height + pad, visible - 40)))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsPanel: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                       // SwiftUI draws the glass shadow
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        title = "Fairy Cursor Settings"
        // The rest of the app is light glass; keep this window in the same light.
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// Gives the borderless window edges you can resize from: a thin band along the card's border
/// (the card sits `inset` in from the window's transparent edge, which is room for its shadow).
/// Everywhere else, clicks go to the content as usual.
final class ResizableFrameView: NSView {
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }

    private let inset: CGFloat
    /// How far outside / inside the card's edge still grabs it.
    private let outside: CGFloat = 8
    private let inside: CGFloat = 5

    init(inset: CGFloat) {
        self.inset = inset
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func embed(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private var card: NSRect { bounds.insetBy(dx: inset, dy: inset) }

    /// The edge band resizes; it must not start a move-by-background drag instead.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func edges(at p: NSPoint) -> Edges {
        let grab = card.insetBy(dx: -outside, dy: -outside)
        guard grab.contains(p), !card.insetBy(dx: inside, dy: inside).contains(p) else { return [] }
        var e: Edges = []
        if p.x <= card.minX + inside { e.insert(.left) }
        if p.x >= card.maxX - inside { e.insert(.right) }
        if p.y <= card.minY + inside { e.insert(.bottom) }
        if p.y >= card.maxY - inside { e.insert(.top) }
        return e
    }

    /// The window server sends clicks on fully transparent pixels to the window underneath, so
    /// the grab band just outside the card gets a fill too faint to see.
    override func draw(_ dirtyRect: NSRect) {
        // Square outside, so the corners (where the card curves away) can be grabbed too.
        let ring = NSBezierPath(rect: card.insetBy(dx: -outside, dy: -outside))
        ring.append(NSBezierPath(roundedRect: card, xRadius: 26, yRadius: 26))
        ring.windingRule = .evenOdd
        NSColor(white: 1, alpha: 0.004).setFill()
        ring.fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return edges(at: local).isEmpty ? super.hitTest(point) : self
    }

    override func resetCursorRects() {
        let c = card, o = outside, i = inside, band = o + i
        let corner = band
        func add(_ r: NSRect, _ position: NSCursor.FrameResizePosition) {
            addCursorRect(r, cursor: .frameResize(position: position, directions: .all))
        }
        add(NSRect(x: c.minX - o, y: c.minY + corner - o, width: band, height: c.height - 2 * corner + 2 * o), .left)
        add(NSRect(x: c.maxX - i, y: c.minY + corner - o, width: band, height: c.height - 2 * corner + 2 * o), .right)
        add(NSRect(x: c.minX + corner - o, y: c.minY - o, width: c.width - 2 * corner + 2 * o, height: band), .bottom)
        add(NSRect(x: c.minX + corner - o, y: c.maxY - i, width: c.width - 2 * corner + 2 * o, height: band), .top)
        add(NSRect(x: c.minX - o, y: c.minY - o, width: corner, height: corner), .bottomLeft)
        add(NSRect(x: c.maxX - i, y: c.minY - o, width: corner, height: corner), .bottomRight)
        add(NSRect(x: c.minX - o, y: c.maxY - i, width: corner, height: corner), .topLeft)
        add(NSRect(x: c.maxX - i, y: c.maxY - i, width: corner, height: corner), .topRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        let e = edges(at: convert(event.locationInWindow, from: nil))
        // Not on an edge: a click on the card's background (nothing in SwiftUI took it) moves the window.
        guard !e.isEmpty else { return window.performDrag(with: event) }
        let start = NSEvent.mouseLocation
        let f0 = window.frame
        let minSize = window.contentMinSize
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp {
            let now = NSEvent.mouseLocation
            let dx = now.x - start.x, dy = now.y - start.y
            var f = f0
            if e.contains(.right) { f.size.width = max(minSize.width, f0.width + dx) }
            if e.contains(.left) {
                f.size.width = max(minSize.width, f0.width - dx)
                f.origin.x = f0.maxX - f.width
            }
            if e.contains(.top) { f.size.height = max(minSize.height, f0.height + dy) }
            if e.contains(.bottom) {
                f.size.height = max(minSize.height, f0.height - dy)
                f.origin.y = f0.maxY - f.height
            }
            window.setFrame(f, display: true)
        }
        window.invalidateCursorRects(for: self)
    }
}

// MARK: - View

/// Quiet ink, one soft blue for switches that are on; sections are separated by space, not lines.
private enum Ink {
    static let primary = Theme.text
    static let secondary = Theme.muted
    static let faint = Theme.muted.opacity(0.7)
    static let accent = Color(hue: 212 / 360, saturation: 0.60, brightness: 0.80)
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings
    let close: () -> Void

    /// Room around the card for its shadow (the window itself is transparent).
    static let shadowInset: CGFloat = 28
    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    /// The card's natural size; the window opens at it and can be resized from there.
    static let idealSize = CGSize(width: 420, height: 706)
    static let minSize = CGSize(width: 340, height: 300)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title stays put; the sections scroll under it when the window is short.
            HStack(alignment: .center) {
                Text("Settings")
                    .font(Theme.font(20, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer()
                CloseButton(action: close)
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 20)

            ScrollView(.vertical) {
                sections
                    .padding(.horizontal, 30)
                    .padding(.bottom, 28)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: Self.minSize.width, maxWidth: .infinity, minHeight: Self.minSize.height, maxHeight: .infinity, alignment: .topLeading)
        // Liquid glass, same recipe as the notes: a light plate over live glass, a hairline and a
        // lit rim for the edge, a layered slate shadow underneath.
        .background {
            shape
                .fill(Theme.plate)
                .glassEffect(.regular.tint(.white.opacity(0.30)), in: shape)
                .overlay(shape.strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                .overlay(shape.inset(by: 0.5).strokeBorder(Theme.rim, lineWidth: 1).opacity(0.9))
                .background(CardShadow(shape: shape, lift: 1.2))
        }
        .clipShape(shape)
        .padding(SettingsView.shadowInset)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 26) {
            section("Screenshots") {
                ToggleRow(
                    title: "Keep every screenshot",
                    detail: settings.keepScreenshots
                        ? "Each one is saved as you take it. Shaking only lets go of it."
                        : "Nothing is saved unless you drop it somewhere. Shaking throws it away.",
                    isOn: $settings.keepScreenshots
                )
                FolderRow(
                    title: "Save to",
                    folder: settings.screenshotsFolder,
                    choose: model.chooseScreenshotsFolder
                )
                .opacity(settings.keepScreenshots ? 1 : 0.45)
            }

            section("Notes") {
                FolderRow(
                    title: "Notes folder",
                    folder: settings.notesFolder,
                    detail: "Each note is a Markdown file you can open anywhere.",
                    choose: model.chooseNotesFolder
                )
                ToggleRow(title: "Hold ⌥ on empty space for a note", isOn: $model.summonEnabled)
            }

            section("General") {
                ToggleRow(title: "Show the fairy when it’s empty", isOn: $model.showWhenIdle)
                ToggleRow(title: "Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            section("Permissions") {
                PermissionRow(title: "Accessibility", granted: model.accessibility, open: Permissions.openAccessibilitySettings)
                PermissionRow(title: "Screen recording", granted: model.screenRecording, open: Permissions.openScreenRecordingSettings)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A small tracked label, then rows on one surface.
    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label.uppercased())
                .font(Theme.font(10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Ink.faint)
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Rows on a brighter patch of the same glass, not a card of their own.
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.42))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .inset(by: 0.5).strokeBorder(Theme.rim, lineWidth: 1).opacity(0.8)
                        )
                )
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(13.5, weight: .medium)).foregroundStyle(Ink.primary)
                if let detail = detail {
                    Text(detail)
                        .font(Theme.font(12))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeOut(duration: 0.2), value: detail)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Ink.accent)
        }
    }
}

private struct FolderRow: View {
    let title: String
    let folder: URL
    var detail: String? = nil
    let choose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title).font(Theme.font(13.5, weight: .medium)).foregroundStyle(Ink.primary)
                Spacer(minLength: 8)
                QuietButton(title: "Change…", action: choose)
                QuietButton(title: "Open", action: { AppSettings.open(folder) })
            }
            Text(AppSettings.displayPath(folder))
                .font(Theme.font(12))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
            if let detail = detail {
                Text(detail).font(Theme.font(12)).foregroundStyle(Ink.faint)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.font(13.5, weight: .medium)).foregroundStyle(Ink.primary)
            Spacer(minLength: 8)
            if granted {
                Text("Allowed").font(Theme.font(12)).foregroundStyle(Ink.faint)
            } else {
                QuietButton(title: "Allow…", action: open)
            }
        }
    }
}

/// A small glass pill: quiet at rest, it lifts and denses a little on hover.
private struct QuietButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(12, weight: .medium))
                .foregroundStyle(hovering ? Ink.primary : Ink.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .glassEffect(.regular.tint(.white.opacity(hovering ? 0.45 : 0.25)).interactive(), in: Capsule())
                .offset(y: hovering ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Closes the window: a small glass circle, quiet until hovered.
private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Ink.primary : Ink.faint)
                .frame(width: 24, height: 24)
                .glassEffect(.regular.tint(.white.opacity(hovering ? 0.45 : 0.2)).interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
