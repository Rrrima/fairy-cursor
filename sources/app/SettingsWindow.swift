import AppKit
import FairyCore
import FairyKit
import ServiceManagement
import SwiftUI

/// Everything the settings window shows that isn't a stored setting: which capabilities are on,
/// launch at login, and the permissions.
@MainActor
final class SettingsModel: ObservableObject {
    let settings = AppSettings.shared
    let updates = Updates.shared
    let capabilities: CapabilityRegistry
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var granted: Set<Permission> = []

    init(capabilities: CapabilityRegistry) {
        self.capabilities = capabilities
        refresh()
    }

    func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        granted = Set(Permission.allCases.filter(\.isGranted))
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[FairyCursor] launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func chooseCapturesFolder() {
        guard let url = Folders.choose(startingAt: settings.capturesFolder, prompt: "Use for captures") else { return }
        settings.capturesFolder = url
    }
}

/// A borderless, transparent window: the white card SwiftUI draws is the whole window. Moves by its background, closes on Esc or its own close button; reused while open.
@MainActor
final class SettingsWindowController {
    private var window: SettingsPanel?
    private let model: SettingsModel

    init(model: SettingsModel) { self.model = model }

    func show() {
        model.refresh()
        if window == nil {
            let window = SettingsPanel()
            let hosting = NSHostingView(rootView: SettingsView(model: model, settings: model.settings, updates: model.updates, capabilities: model.capabilities, close: { [weak window] in
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
        hasShadow = false                       // SwiftUI draws the card's shadow
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        title = "Fairy Cursor Settings"
        // The card is white paper whatever the system appearance; keep its controls light too.
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
        ring.append(NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22))
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

private typealias Ink = SettingsInk

/// Settings as one white page, like the website: no boxes and no rules. A small grey label opens
/// each group, space separates the groups, and the only tone is the pale patch a capability's own
/// options sit on, so they read as belonging to the switch above them.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var updates: Updates
    @ObservedObject var capabilities: CapabilityRegistry
    let close: () -> Void

    /// Room around the card for its shadow (the window itself is transparent).
    static let shadowInset: CGFloat = 28
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    /// The card's natural size; the window opens at it and can be resized from there.
    static let idealSize = CGSize(width: 440, height: 720)
    static let minSize = CGSize(width: 360, height: 300)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title stays put; the sections scroll under it when the window is short.
            HStack(alignment: .center) {
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Ink.primary)
                Spacer()
                PaperCloseButton(action: close)
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 18)

            ScrollView(.vertical) {
                sections
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
                    .padding(.bottom, 32)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: Self.minSize.width, maxWidth: .infinity, minHeight: Self.minSize.height, maxHeight: .infinity, alignment: .topLeading)
        .background(PaperCard(shape: shape))
        .clipShape(shape)
        .padding(SettingsView.shadowInset)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 34) {
            // What the fairy can do: each one switches on and off on its own, and keeps its own
            // options right under its switch.
            section("Capabilities", spacing: 22) {
                ForEach(capabilities.all.indices, id: \.self) { i in
                    let capability = capabilities.all[i]
                    let manifest = CapabilityRegistry.manifest(of: capability)
                    let on = capabilities.isEnabled(manifest.id)
                    CapabilityRow(manifest: manifest, isOn: Binding(
                        get: { capabilities.isEnabled(manifest.id) },
                        set: { capabilities.setEnabled(manifest.id, $0); model.refresh() }
                    ), options: on ? capability.settingsView() : nil)
                }
            }

            section("General") {
                ChoiceRow(
                    title: "Following",
                    detail: Self.followDetail(settings.followStyle),
                    options: [(.close, "Close"), (.calm, "Calm"), (.lively, "Lively")],
                    selection: $settings.followStyle
                )
                FolderRow(
                    title: "Captures folder",
                    folder: settings.capturesFolder,
                    detail: "Kept screenshots and screen recordings are saved here.",
                    choose: model.chooseCapturesFolder
                )
                ToggleRow(title: "Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            if updates.isAvailable {
                section("Updates") {
                    UpdateRow(version: updates.version, waiting: updates.waiting, check: updates.check)
                    ToggleRow(title: "Check automatically", detail: "Looks for a new version about once a day.",
                              isOn: $updates.checksAutomatically)
                }
            }

            section("Permissions") {
                ForEach(Permission.allCases.filter { capabilities.neededPermissions.contains($0) }, id: \.self) { permission in
                    PermissionRow(title: permission.title, granted: model.granted.contains(permission), open: { Permissions.allow(permission) })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What each way of following looks like, in a line.
    private static func followDetail(_ style: FollowStyle) -> String {
        switch style {
        case .close: return "What you hold stays right by the cursor."
        case .calm: return "What you hold glides after the cursor."
        case .lively: return "What you hold swings and leans as you move, like on the website."
        }
    }

    /// A small grey label, then its rows straight on the page.
    private func section<Content: View>(_ label: String, spacing: CGFloat = 16, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.faint)
            VStack(alignment: .leading, spacing: spacing) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One capability: its name with its keys beside it, what it does in a line, and its switch.
/// While it's on, its own options sit on a pale patch right below.
private struct CapabilityRow: View {
    let manifest: CapabilityManifest
    @Binding var isOn: Bool
    let options: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 9) {
                        Text(manifest.name)
                            .font(.system(size: 14.5, weight: .semibold))
                            .tracking(-0.1)
                            .foregroundStyle(Ink.primary)
                            .fixedSize()
                        // One chip per shortcut, so three of them still fit beside the name.
                        HStack(spacing: 4) {
                            ForEach(manifest.shortcuts, id: \.self) { KeyChip($0) }
                        }
                        .opacity(isOn ? 1 : 0.45)
                    }
                    Text(manifest.summary)
                        .font(.system(size: 12.5))
                        .lineSpacing(1.5)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Ink.primary)
                    .padding(.top, 2)
            }
            if let options = options {
                options
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(white: 0.972)))
            }
        }
    }
}

/// Which version this is, and a button that looks for a newer one (or installs the one found).
private struct UpdateRow: View {
    let version: String
    let waiting: String?
    let check: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Fairy Cursor \(version)").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.primary)
                if let waiting = waiting {
                    Text("\(waiting) is ready to install.").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                }
            }
            Spacer(minLength: 8)
            if let waiting = waiting {
                InkButton(title: "Update to \(waiting)…", action: check)
            } else {
                QuietButton(title: "Check for updates", action: check)
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
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.primary)
            Spacer(minLength: 8)
            PermissionState(granted: granted, open: open)
        }
    }
}

/// "Allowed" with a tick, or a button that opens the right pane of System Settings.
struct PermissionState: View {
    let granted: Bool
    let open: () -> Void

    var body: some View {
        if granted {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold))
                Text("Allowed").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Ink.faint)
            .frame(height: 24)
        } else {
            InkButton(title: "Allow…", action: open)
        }
    }
}

/// The one dark button on a page: the thing to do next.
struct InkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(Capsule().fill(Ink.primary.opacity(hovering ? 0.82 : 1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The white card Settings and the welcome guide are drawn on: paper, a hairline, a soft shadow.
struct PaperCard<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(Color.white)
            .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            .background(CardShadow(shape: shape, lift: 1.3))
    }
}

/// Closes the window: a small cross, on a pale disc once hovered.
struct PaperCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Ink.primary : Ink.faint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Ink.fill.opacity(hovering ? 1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
