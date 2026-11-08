import AppKit
import SwiftUI

enum NoteLayout {
    /// The glass pill that rings the cursor while ⌥ is held.
    static let summonSize = CGSize(width: 46, height: 34)
    static let summonRadius: CGFloat = 12
    /// A new note's glass card.
    static let noteSize = CGSize(width: 304, height: 224)
    static let minNoteSize = CGSize(width: 190, height: 120)
    static let radius: CGFloat = 18
    /// Room around the card for its shadow to fade out; the panel is this much larger on every side.
    static let inset: CGFloat = 44
}

/// One open note's live state; edits go back to the store through `onChange`.
@MainActor
final class NoteModel: ObservableObject {
    @Published private(set) var note: Note
    /// Grow out of the summon pill instead of appearing at full size.
    let growsIn: Bool
    let focusOnOpen: Bool
    var onChange: ((Note) -> Void)?

    init(note: Note, growsIn: Bool, focusOnOpen: Bool) {
        self.note = note
        self.growsIn = growsIn
        self.focusOnOpen = focusOnOpen
    }

    var text: String {
        get { note.text }
        set {
            guard newValue != note.text else { return }
            note.text = newValue
            note.updatedAt = Date()
            onChange?(note)
        }
    }
}

/// Borderless glass panel that takes typing without activating the app (like Spotlight).
final class NotePanel: NSPanel {
    let noteID: UUID

    init(noteID: UUID, frame: NSRect) {
        self.noteID = noteID
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                       // SwiftUI draws the glass shadow
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct NoteView: View {
    @ObservedObject var model: NoteModel
    let onClose: () -> Void
    let onDelete: () -> Void
    let onOpenOrigin: () -> Void
    /// Where `![](…)` paths in the note resolve (the notes folder).
    let attachmentsBase: URL
    /// Double-click while carrying screenshots: Markdown for them, or nil.
    let onDoubleClick: () -> String?

    @State private var grown = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let full = geo.size
            let size = grown ? full : NoteLayout.summonSize
            let shape = RoundedRectangle(cornerRadius: grown ? NoteLayout.radius : NoteLayout.summonRadius, style: .continuous)
            ZStack(alignment: .topLeading) {
                shape
                    .fill(Color.white.opacity(0.42))
                    .glassEffect(.regular.tint(.white.opacity(0.22)), in: shape)
                    .overlay(shape.strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                    .overlay(shape.inset(by: 0.5).strokeBorder(Theme.rim, lineWidth: 1).opacity(0.9))
                    .background(CardShadow(shape: shape, lift: grown ? 1 : 0.5))
                if grown {
                    content
                        .frame(width: full.width, height: full.height)
                        .clipShape(shape)
                        .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.08)))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .padding(NoteLayout.inset)
        .onHover { hovering = $0 }
        .onAppear {
            if model.growsIn {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) { grown = true }
            } else {
                grown = true
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 12)
            MarkdownEditor(text: $model.text, focusOnAppear: model.focusOnOpen, onDoubleClick: onDoubleClick)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            if !images.isEmpty { thumbnails }
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            OriginChip(origin: model.note.origin, action: onOpenOrigin)
            Spacer(minLength: 4)
            if hovering {
                Group {
                    HeaderButton(symbol: "trash", help: "Delete note", action: onDelete)
                    HeaderButton(symbol: "xmark", help: "Put away (find it again in the menu bar)", action: onClose)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(WindowDragArea())
    }

    private var footer: some View {
        HStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(editedLabel)
                    .font(Theme.font(11))
                    .foregroundStyle(Theme.muted.opacity(0.85))
                    .help("Created \(model.note.createdAt.formatted(date: .abbreviated, time: .shortened))\nEdited \(model.note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            Spacer(minLength: 0)
            ResizeGrip()
                .frame(width: 18, height: 18)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.bottom, 3)
        .frame(height: 26)
        .background(WindowDragArea())
    }

    /// Screenshots referenced by the note, newest last.
    private var images: [URL] {
        let text = model.note.text as NSString
        return MarkdownStyler.image.matches(in: model.note.text, range: NSRange(location: 0, length: text.length)).map {
            attachmentsBase.appendingPathComponent(text.substring(with: $0.range(at: 1)))
        }
    }

    private var thumbnails: some View {
        FlowLayout(spacing: 6) {
            ForEach(images, id: \.self) { url in
                if let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 {
                    // Fixed size from the aspect ratio, so a wide crop stays inside the note.
                    let aspect = image.size.width / image.size.height
                    let height = min(64, 270 / aspect)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: height * aspect, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var editedLabel: String {
        let note = model.note
        let verb = note.updatedAt.timeIntervalSince(note.createdAt) < 1 ? "Created" : "Edited"
        if Date().timeIntervalSince(note.updatedAt) < 60 { return "\(verb) just now" }
        return "\(verb) \(note.updatedAt.formatted(.relative(presentation: .named)))"
    }
}

/// Where the note came from; click to go back there.
private struct OriginChip: View {
    let origin: NoteOrigin
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.frame(width: 14, height: 14)
                Text(origin.label)
                    .font(Theme.font(11.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.slate.opacity(0.05)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(origin.detail)
    }

    @ViewBuilder private var icon: some View {
        if origin.kind != .desktop, let image = NotesController.appIcon(bundleID: origin.bundleID) {
            Image(nsImage: image).resizable()
        } else {
            Image(systemName: origin.kind == .desktop ? "desktopcomputer" : "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hover ? Theme.text : Theme.muted)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.slate.opacity(hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Header/footer background that drags the window.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

/// Bottom-right grip that resizes the panel, keeping its top-left corner in place.
private struct ResizeGrip: View {
    var body: some View {
        ZStack {
            ResizeArea()
            Path { p in
                p.move(to: CGPoint(x: 13, y: 6)); p.addLine(to: CGPoint(x: 6, y: 13))
                p.move(to: CGPoint(x: 13, y: 10)); p.addLine(to: CGPoint(x: 10, y: 13))
            }
            .stroke(Theme.muted.opacity(0.45), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .allowsHitTesting(false)
        }
    }

    private struct ResizeArea: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { ResizeView() }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    final class ResizeView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
        }

        override func mouseDown(with event: NSEvent) {
            guard let window = window else { return }
            let start = NSEvent.mouseLocation
            let startFrame = window.frame
            let pad = NoteLayout.inset * 2
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp {
                let now = NSEvent.mouseLocation
                let width = max(NoteLayout.minNoteSize.width + pad, startFrame.width + now.x - start.x)
                let height = max(NoteLayout.minNoteSize.height + pad, startFrame.height - (now.y - start.y))
                window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), display: true)
            }
        }
    }
}

// MARK: - Summon pill

@MainActor
final class SummonModel: ObservableObject {
    @Published var visible = false
}

/// Click-through panel centred on the cursor hotspot that shows the glass pill.
final class SummonPanel: NSPanel {
    let model = SummonModel()
    static let size = CGSize(width: NoteLayout.summonSize.width + 80, height: NoteLayout.summonSize.height + 80)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        // Like the fairy: out of screenshots and recordings unless FAIRY_CAPTURABLE=1 (for demos).
        sharingType = ProcessInfo.processInfo.environment["FAIRY_CAPTURABLE"] == "1" ? .readOnly : .none
        setAccessibilityElement(false)
        contentView = NSHostingView(rootView: SummonView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// `mouse` in AppKit screen coordinates.
    @MainActor func show(at mouse: CGPoint) {
        setFrameOrigin(CGPoint(x: mouse.x - Self.size.width / 2, y: mouse.y - Self.size.height / 2))
        guard !model.visible else { return }
        orderFrontRegardless()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) { model.visible = true }
    }

    @MainActor func hide(animated: Bool = true) {
        guard model.visible else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.12)) { model.visible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                MainActor.assumeIsolated { if self?.model.visible == false { self?.orderOut(nil) } }
            }
        } else {
            model.visible = false
            orderOut(nil)
        }
    }
}

private struct SummonView: View {
    @ObservedObject var model: SummonModel

    var body: some View {
        // Grows out of a bead the size of the fairy's idle orb.
        let size = model.visible ? NoteLayout.summonSize : CGSize(width: FairyLayout.orbSize, height: FairyLayout.orbSize)
        let shape = RoundedRectangle(cornerRadius: model.visible ? NoteLayout.summonRadius : FairyLayout.orbSize / 2, style: .continuous)
        shape
            .fill(Theme.plate)
            .glassEffect(.regular.tint(.white.opacity(0.24)), in: shape)
            .overlay(shape.strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .overlay(shape.inset(by: 0.5).strokeBorder(Theme.rim, lineWidth: 1).opacity(0.9))
            .background(CardShadow(shape: shape, lift: 0.55))
            .frame(width: size.width, height: size.height)
            .opacity(model.visible ? 1 : 0)
            .frame(width: SummonPanel.size.width, height: SummonPanel.size.height)
    }
}

/// Layered slate shadow — a crisp contact edge, a mid key shadow and a wide ambient one — with
/// the card's own shape cut out, so it never shows through translucent glass as a grey haze.
/// `lift` scales the spread: small things sit close to the surface, a note floats higher.
struct CardShadow<S: Shape>: View {
    let shape: S
    var lift: CGFloat = 1

    var body: some View {
        ZStack {
            layer(opacity: 0.10, blur: 0.8, y: 0.6)                   // contact: defines the edge
            layer(opacity: 0.07, blur: 5 * lift, y: 3 * lift)         // key: the main lift
            layer(opacity: 0.06, blur: 16 * lift, y: 12 * lift)       // ambient: soft, far, low
        }
        .mask {
            Rectangle()
                .padding(-80)
                .overlay(shape.blendMode(.destinationOut))
                .compositingGroup()
        }
        .allowsHitTesting(false)
    }

    private func layer(opacity: Double, blur: CGFloat, y: CGFloat) -> some View {
        shape
            .fill(Theme.slate.opacity(opacity))
            .blur(radius: blur)
            .offset(y: y)
    }
}

/// Lays its subviews out in rows, wrapping to the next row when one would overflow the width.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
