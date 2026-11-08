import AppKit

/// Moves the panel after the cursor with a soft spring so it feels like a companion, not a
/// cursor decoration. Positions are in AppKit screen coordinates (origin bottom-left).
@MainActor
final class Follower {
    private let panel: NSPanel
    private var timer: Timer?
    private var position: CGPoint = .zero
    private var lastTick: CFTimeInterval = CACurrentMediaTime()
    private var started = false

    /// Offset of the content's top-left from the cursor hotspot, in points.
    var offset = CGPoint(x: 14, y: 18)
    /// Response speed (1/s); higher snaps faster.
    var stiffness: Double = 16

    init(panel: NSPanel) {
        self.panel = panel
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // The panel is ordered front once; anything that takes it off screen (another app's
        // "Hide Others" hides accessory apps too, display reconfiguration, Spaces transitions)
        // would otherwise leave the pile invisible for good while it is still being carried.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didHideNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { NSApp.unhideWithoutActivation() }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassertVisibility() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassertVisibility() }
            },
        ]
    }

    private var observers: [NSObjectProtocol] = []

    private func reassertVisibility() {
        guard started else { return }
        panel.orderFrontRegardless()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        let mouse = NSEvent.mouseLocation
        let target = targetOrigin(for: mouse)
        if !started {
            position = target
            started = true
            panel.setFrameOrigin(position)
            panel.orderFrontRegardless()
            return
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        let alpha = 1 - exp(-dt * stiffness)
        position.x += (target.x - position.x) * alpha
        position.y += (target.y - position.y) * alpha
        if abs(position.x - panel.frame.origin.x) > 0.05 || abs(position.y - panel.frame.origin.y) > 0.05 {
            panel.setFrameOrigin(position)
        }
    }

    /// Panel origin so the content's top-left sits below-right of the cursor, flipping to the
    /// other side near screen edges so the card stays visible.
    private func targetOrigin(for mouse: CGPoint) -> CGPoint {
        let size = FairyLayout.panelSize
        let inset = FairyLayout.inset
        let contentW = FairyLayout.thumbMax.width + 14
        let contentH = FairyLayout.thumbMax.height + 40

        var contentTopLeft = CGPoint(x: mouse.x + offset.x, y: mouse.y - offset.y)
        // `contains` excludes the max edges, where the cursor sits at the very top/right of a
        // display; fall back to the nearest screen rather than whichever one has key focus.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.screens.min(by: { distance($0.frame, mouse) < distance($1.frame, mouse) }) {
            let f = screen.visibleFrame
            if contentTopLeft.x + contentW > f.maxX { contentTopLeft.x = mouse.x - offset.x - contentW }
            if contentTopLeft.y - contentH < f.minY { contentTopLeft.y = mouse.y + offset.y + contentH }
        }
        return CGPoint(x: contentTopLeft.x - inset, y: contentTopLeft.y + inset - size.height)
    }

    private func distance(_ rect: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
