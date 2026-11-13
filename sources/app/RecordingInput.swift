import AppKit
import CoreGraphics

/// The keyboard and wheel input that drives screen recording, taken before other apps see it:
///   - ⌘⇧6 starts or stops a recording (macOS assigns it to "screenshot of the Touch Bar", which
///     does nothing on Macs without one; this tap sees it first and keeps it);
///   - while recording, ⌥ + scroll zooms the recorded area, and the scroll never reaches the app
///     underneath.
/// Needs Accessibility, like the rest of the fairy. Runs on the main run loop.
@MainActor
final class RecordingInput {
    /// ⌘⇧6 was pressed.
    var onToggle: () -> Void = {}
    /// ⌥ + scroll while recording: positive zooms in. In "natural" units: one wheel notch ≈ 0.12.
    var onZoom: (CGFloat) -> Void = { _ in }
    /// Whether ⌥ + scroll should be taken (only while recording).
    var isRecording: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static let toggleKeyCode: Int64 = 22   // the "6" key
    static let shortcutLabel = "⌘⇧6"

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: recordingInputCallback, userInfo: refcon) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Returns false to swallow the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .keyDown:
            let flags = event.flags
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.toggleKeyCode,
                  flags.contains(.maskCommand), flags.contains(.maskShift),
                  !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return true }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onToggle() }
            return false
        case .scrollWheel:
            guard isRecording(), event.flags.contains(.maskAlternate) else { return true }
            onZoom(Self.zoomAmount(for: event))
            return false
        default:
            return true
        }
    }

    /// Trackpads send many small pixel deltas, mice a few line notches; both map to the same feel.
    /// Scrolling up (content moving down, before any "natural scrolling" flip) zooms in.
    private static func zoomAmount(for event: CGEvent) -> CGFloat {
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        var delta: CGFloat
        if continuous {
            delta = CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)) * 0.006
        } else {
            delta = CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)) * 0.12
        }
        // Some mice report ⌥-scroll on the horizontal axis.
        if delta == 0 {
            delta = continuous
                ? CGFloat(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) * 0.006
                : CGFloat(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)) * 0.12
        }
        // Undo "natural scrolling" so the same finger direction always zooms the same way.
        if NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice == true { delta = -delta }
        return delta
    }
}

private func recordingInputCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                    refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let input = Unmanaged<RecordingInput>.fromOpaque(refcon).takeUnretainedValue()
    let pass = MainActor.assumeIsolated { input.handle(type: type, event: event) }
    return pass ? Unmanaged.passUnretained(event) : nil
}
