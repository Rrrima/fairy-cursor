import AppKit
import FairyKit
import SwiftUI

/// What you see while recording, and never in the video: a soft blue outline around the area
/// being recorded (it shrinks and slides as you zoom) and a small glass pill at the top of the
/// screen with the elapsed time and the zoom hint. Click-through; kept out of the capture by
/// window ID (see `ScreenRecorder.start`).
@MainActor
final class RecordingFrame {
    private let panel: NSPanel
    private let outline = CAShapeLayer()
    private let display: CGRect          // global points, top-left origin
    private let model = PillModel()
    private var timer: Timer?
    private let started = Date()

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(displayID: CGDirectDisplayID) {
        display = CGDisplayBounds(displayID)
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID }
        let frame = screen?.frame ?? NSScreen.main?.frame ?? .zero

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.setFrame(frame, display: false)

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        // One soft blue line: the recording is the live thing on screen.
        outline.fillColor = nil
        outline.strokeColor = NSColor(calibratedHue: 212 / 360, saturation: 0.6, brightness: 0.86, alpha: 0.9).cgColor
        outline.lineWidth = 2
        outline.shadowColor = NSColor(calibratedHue: 212 / 360, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor
        outline.shadowOpacity = 0.45
        outline.shadowRadius = 6
        outline.shadowOffset = .zero
        root.layer?.addSublayer(outline)

        // The pill sits just under the menu bar, centred.
        let pill = NSHostingView(rootView: RecordingPill(model: model))
        pill.frame = NSRect(x: 0, y: 0, width: 280, height: 44)
        let menuBar = frame.maxY - (screen?.visibleFrame.maxY ?? frame.maxY)
        pill.frame.origin = NSPoint(x: (frame.width - pill.frame.width) / 2, y: frame.height - menuBar - pill.frame.height - 8)
        root.addSubview(pill)
        panel.contentView = root
    }

    func show(area: @escaping () -> CGRect) {
        update(area())
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.update(area())
                self.model.elapsed = Int(Date().timeIntervalSince(self.started))
            }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func update(_ area: CGRect) {
        guard area.width > 0 else { return }
        // Global top-left → this panel's bottom-left coordinates.
        let local = CGRect(x: area.minX - display.minX, y: display.maxY - area.maxY, width: area.width, height: area.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outline.path = CGPath(roundedRect: local.insetBy(dx: 1, dy: 1), cornerWidth: 10, cornerHeight: 10, transform: nil)
        CATransaction.commit()
    }
}

@MainActor
private final class PillModel: ObservableObject {
    @Published var elapsed = 0
}

/// "● 0:42 · ⌥ scroll to zoom · ⌘⇧6 to stop" on one glass pill; the dot breathes.
private struct RecordingPill: View {
    @ObservedObject var model: PillModel
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hue: 212 / 360, saturation: 0.62, brightness: 0.86))
                .frame(width: 7, height: 7)
                .opacity(breathe ? 1 : 0.45)
                .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: breathe)
            Text(String(format: "%d:%02d", model.elapsed / 60, model.elapsed % 60))
                .font(Theme.font(12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            Text("⌥ scroll to zoom · \(RecordingInput.shortcutLabel) to stop")
                .font(Theme.font(11.5))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular.tint(.white.opacity(0.3)), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { breathe = true }
    }
}
