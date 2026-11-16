import AppKit
import FairyCore

/// The pen and highlighter while recording: a clear window over the recorded display that is
/// click-through until a tool is picked up, then takes the mouse and draws. Unlike the blue
/// outline and the pill, this window is *in* the video: the ink is for the viewer.
///
/// It never activates the app or becomes key, so the app being recorded keeps looking active.
@MainActor
final class InkOverlay {
    private let panel: InkPanel
    private let view: InkView
    /// Called when the tool changes, so the pill can say what's in hand.
    var onToolChanged: (InkTool?) -> Void = { _ in }

    var tool: InkTool? { view.ink.tool }

    init(displayID: CGDirectDisplayID) {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
        let frame = screen?.frame ?? NSScreen.main?.frame ?? .zero
        panel = InkPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        // Under the outline and the pill (statusBar + 1), over every app.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.setFrame(frame, display: false)
        view = InkView(frame: NSRect(origin: .zero, size: frame.size))
        InkStyle.forgetCursors()
        panel.contentView = view
    }

    func show() { panel.orderFrontRegardless() }

    func close() {
        if view.ink.isDrawing { _ = press(.done) }
        BackgroundCursor.allow(false)
        panel.orderOut(nil)
    }

    /// Returns whether the key did something (if not, it goes on to the app underneath).
    func press(_ key: InkKey) -> Bool {
        let before = view.ink.tool
        let used = view.ink.press(key)
        guard used else { return false }
        let after = view.ink.tool
        if key == .done || (before != nil && after == nil) {
            view.fadeAway()
        } else {
            view.redraw()
        }
        if before != after { toolChanged(after) }
        return true
    }

    private func toolChanged(_ tool: InkTool?) {
        panel.ignoresMouseEvents = tool == nil
        // A background app can't normally set the cursor; this window needs to while drawing.
        BackgroundCursor.allow(tool != nil)
        view.tool = tool
        if tool == nil { NSCursor.arrow.set() }
        onToolChanged(tool)
    }
}

/// Never key, never main: drawing doesn't take focus from the app being recorded.
private final class InkPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class InkView: NSView {
    var ink = Ink()
    var tool: InkTool? {
        didSet {
            cursor.set()
            holdCursor(tool != nil)
        }
    }
    /// The active app keeps setting its own cursor (an I-beam over text) whenever the mouse
    /// rests; while a tool is in hand, keep putting the tip back.
    private var cursorTimer: Timer?

    private func holdCursor(_ on: Bool) {
        cursorTimer?.invalidate()
        cursorTimer = nil
        guard on else { return }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cursor.set() }
        }
    }

    /// Highlighter strokes sit under pen strokes, so writing over a highlight stays crisp.
    private let highlights = CALayer()
    private let lines = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(highlights)
        layer?.addSublayer(lines)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        cursor.set()
        ink.beginStroke(at: convert(event.locationInWindow, from: nil))
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        cursor.set()
        ink.extendStroke(to: convert(event.locationInWindow, from: nil))
        redrawCurrent()
    }

    override func mouseUp(with event: NSEvent) {
        cursor.set()
        ink.endStroke()
        redraw()
    }

    override func mouseMoved(with event: NSEvent) { if tool != nil { cursor.set() } }
    override func cursorUpdate(with event: NSEvent) { if tool != nil { cursor.set() } }

    private var cursor: NSCursor { tool.map(InkStyle.cursor(for:)) ?? .arrow }

    // MARK: Drawing

    /// One layer per stroke: a whole stroke is a single path, so a highlighter crossing itself
    /// doesn't darken where it overlaps.
    func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlights.opacity = 1
        lines.opacity = 1
        highlights.sublayers = nil
        lines.sublayers = nil
        for stroke in ink.strokes { add(stroke) }
        if let current = ink.current { add(current).name = "current" }
        CATransaction.commit()
    }

    private func redrawCurrent() {
        guard let current = ink.current else { return }
        let parent = current.tool == .highlighter ? highlights : lines
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = parent.sublayers?.last(where: { $0.name == "current" }) as? CAShapeLayer {
            layer.path = Ink.path(through: current.points)
        } else {
            add(current).name = "current"
        }
        CATransaction.commit()
    }

    @discardableResult
    private func add(_ stroke: Ink.Stroke) -> CAShapeLayer {
        let layer = InkStyle.layer(for: stroke.tool)
        layer.frame = bounds
        layer.path = Ink.path(through: stroke.points)
        (stroke.tool == .highlighter ? highlights : lines).addSublayer(layer)
        return layer
    }

    /// The ink lifts off rather than vanishing in one frame.
    func fadeAway() {
        for container in [highlights, lines] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = container.presentation()?.opacity ?? 1
            fade.toValue = 0
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            container.opacity = 0
            container.add(fade, forKey: "fade")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, self.ink.strokes.isEmpty, self.ink.current == nil else { return }
            self.redraw()
        }
    }
}

/// How the two tools look, on screen and as the cursor.
enum InkStyle {
    /// The fairy's blue: the ink is the live thing on screen.
    static let penColor = NSColor(calibratedHue: 212 / 360, saturation: 0.72, brightness: 0.88, alpha: 1)
    static let penWidth: CGFloat = 4
    /// A soft marker yellow, see-through so the text under it stays readable.
    static let highlighterColor = NSColor(calibratedHue: 52 / 360, saturation: 0.75, brightness: 1, alpha: 0.38)
    static let highlighterWidth: CGFloat = 22

    static func layer(for tool: InkTool) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        switch tool {
        case .pen:
            layer.strokeColor = penColor.cgColor
            layer.lineWidth = penWidth
            // A faint lift, so the line reads on any background.
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 1.5
            layer.shadowOffset = CGSize(width: 0, height: -0.5)
        case .highlighter:
            layer.strokeColor = highlighterColor.cgColor
            layer.lineWidth = highlighterWidth
        }
        return layer
    }

    private static var cache: [InkTool: NSCursor] = [:]

    /// The cursor size can differ between recordings; build the tips again.
    @MainActor
    static func forgetCursors() { cache = [:] }

    /// The cursor is the tip: a dot the size of the pen line, or the highlighter's flat nib.
    /// Drawn smaller by however much recording enlarged the cursor, so the tip matches the ink.
    @MainActor
    static func cursor(for tool: InkTool) -> NSCursor {
        if let cached = cache[tool] { return cached }
        let scale = CGFloat(CursorScale.enlargement)
        let nib: NSSize
        switch tool {
        case .pen: nib = NSSize(width: penWidth + 4, height: penWidth + 4)
        case .highlighter: nib = NSSize(width: 8, height: highlighterWidth)
        }
        let size = NSSize(width: max(nib.width / scale, 4), height: max(nib.height / scale, 4))
        let image = NSImage(size: NSSize(width: size.width + 4, height: size.height + 4), flipped: false) { rect in
            let body = rect.insetBy(dx: 2, dy: 2)
            let shape: NSBezierPath
            switch tool {
            case .pen:
                shape = NSBezierPath(ovalIn: body)
                penColor.setFill()
            case .highlighter:
                shape = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
                highlighterColor.withAlphaComponent(0.85).setFill()
            }
            shape.fill()
            // A white rim, so the tip shows on dark and light alike.
            NSColor.white.withAlphaComponent(0.95).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
        cache[tool] = cursor
        return cursor
    }
}

/// Lets this app set the cursor while another app is active (SkyLight's
/// "SetsCursorInBackground" connection property, loaded at run time; without it the system
/// arrow stays, and drawing still works).
@MainActor
enum BackgroundCursor {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    private static let api: (connection: ConnectionFn, set: SetPropertyFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let c = dlsym(handle, "CGSMainConnectionID"),
              let s = dlsym(handle, "CGSSetConnectionProperty") else { return nil }
        return (unsafeBitCast(c, to: ConnectionFn.self), unsafeBitCast(s, to: SetPropertyFn.self))
    }()

    static func allow(_ on: Bool) {
        guard let api = api else { return }
        let connection = api.connection()
        _ = api.set(connection, connection, "SetsCursorInBackground" as CFString, (on ? kCFBooleanTrue : kCFBooleanFalse)!)
    }
}
