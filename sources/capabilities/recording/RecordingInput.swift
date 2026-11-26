import AppKit
import CoreGraphics
import FairyCore

/// The keyboard and wheel input that drives screen recording, taken before other apps see it:
///   - ⌘⇧6 starts or stops a recording (macOS assigns it to "screenshot of the Touch Bar", which
///     does nothing on Macs without one; this tap sees it first and keeps it);
///   - while recording, ⌥ + scroll zooms the recorded area, and the scroll never reaches the app
///     underneath; a double-tap of ⌥ goes back to the whole screen.
/// Needs Accessibility, like the rest of the fairy. Runs on the main run loop.
@MainActor
final class RecordingInput {
    /// ⌘⇧6 was pressed.
    var onToggle: () -> Void = {}
    /// ⌥ + scroll while recording: positive zooms in. In "natural" units: one wheel notch ≈ 0.12.
    var onZoom: (CGFloat) -> Void = { _ in }
    /// Whether ⌥ + scroll should be taken (only while recording).
    var isRecording: () -> Bool = { false }
    /// ⌥ went down or up (the recorded area follows the cursor only while it's held).
    var onOptionChanged: (Bool) -> Void = { _ in }
    /// A pen key while recording. Returns whether it was used; unused keys go on to the app.
    var onInkKey: (InkKey) -> Bool = { _ in false }
    /// ⌥ was tapped twice quickly while recording: show the whole screen again.
    var onResetZoom: () -> Void = {}
    /// ⌘⇧9 while recording: open the sound panel (or close it and carry on).
    var onSoundShortcut: () -> Void = {}
    /// Whether the sound panel is open: it then gets the plain keys below.
    var isChoosingSound: () -> Bool = { false }
    /// A key for the sound panel.
    var onSoundKey: (SoundKey) -> Void = { _ in }
    private var optionDown = false
    /// When ⌥ last went down on its own (0: nothing to pair a second tap with).
    private var lastOptionTap: CFTimeInterval = 0
    /// "Following" starts a beat after ⌥ goes down, so the two taps of a double-tap don't tug
    /// the view toward the cursor first. A scroll starts it at once.
    private var pendingFollow: DispatchWorkItem?
    private var followReported = false

    /// Two ⌥ presses this close together are a double-tap.
    static let doubleTapWindow: CFTimeInterval = 0.35
    static let followDelay: TimeInterval = 0.15

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    static let toggleKeyCode: Int64 = 22   // the "6" key
    static let shortcutLabel = "⌘⇧6"
    static let penKeyCode: Int64 = 26      // "7"
    static let highlighterKeyCode: Int64 = 28   // "8"
    static let penLabel = "⌘⇧7"
    static let highlighterLabel = "⌘⇧8"
    static let soundKeyCode: Int64 = 25   // "9"
    static let soundLabel = "⌘⇧9"

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
        pendingFollow?.cancel()
        pendingFollow = nil
    }

    private func optionChanged(_ down: Bool, flags: CGEventFlags) {
        optionDown = down
        if down {
            // Only ⌥ by itself counts as a tap; ⌘⌥ and friends are someone else's shortcut.
            let alone = !flags.contains(.maskCommand) && !flags.contains(.maskShift) && !flags.contains(.maskControl)
            let now = CACurrentMediaTime()
            if alone, isRecording(), now - lastOptionTap < Self.doubleTapWindow {
                lastOptionTap = 0
                onResetZoom()
            } else {
                lastOptionTap = alone ? now : 0
            }
            let work = DispatchWorkItem { [weak self] in self?.reportFollowing() }
            pendingFollow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.followDelay, execute: work)
        } else {
            pendingFollow?.cancel()
            pendingFollow = nil
            if followReported {
                followReported = false
                onOptionChanged(false)
            }
        }
    }

    /// ⌥ has been held long enough (or a scroll came): it's a hold, not a tap.
    private func reportFollowing() {
        pendingFollow?.cancel()
        pendingFollow = nil
        guard optionDown, !followReported else { return }
        followReported = true
        onOptionChanged(true)
    }

    /// Returns false to swallow the event.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .keyDown:
            lastOptionTap = 0   // ⌥ then a key is typing, not half a double-tap
            let flags = event.flags
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let command = flags.contains(.maskCommand), shift = flags.contains(.maskShift)
            let otherModifiers = flags.contains(.maskControl) || flags.contains(.maskAlternate)
            if command, shift, !otherModifiers, code == Self.toggleKeyCode {
                if !repeated { onToggle() }
                return false
            }
            guard isRecording(), !otherModifiers else { return true }
            if command, shift, code == Self.soundKeyCode {
                if !repeated { onSoundShortcut() }
                return false
            }
            // The panel is driven from here, so it never has to take the keyboard from the app
            // being recorded.
            if isChoosingSound() {
                guard !command, !shift else { return true }
                let key: SoundKey?
                switch code {
                case 18: key = .computer        // 1
                case 19: key = .microphone      // 2
                case 126: key = .previous       // ↑
                case 125: key = .next           // ↓
                case 36, 76, 53: key = .done    // return, enter, esc
                default: key = nil
                }
                guard let key = key else { return true }
                if !repeated { onSoundKey(key) }
                return false
            }
            let key: InkKey?
            switch (code, command, shift) {
            case (Self.penKeyCode, true, true): key = .pen
            case (Self.highlighterKeyCode, true, true): key = .highlighter
            case (6, true, false): key = .undo      // ⌘Z
            case (53, false, false): key = .done    // esc
            case (51, false, false), (117, false, false): key = .clear   // ⌫, ⌦
            default: key = nil
            }
            guard let key = key else { return true }
            if repeated { return key == .pen || key == .highlighter ? false : !onInkKey(key) }
            return !onInkKey(key)
        case .flagsChanged:
            let down = event.flags.contains(.maskAlternate)
            if down != optionDown { optionChanged(down, flags: event.flags) }
            return true
        case .scrollWheel:
            guard isRecording(), !isChoosingSound(), event.flags.contains(.maskAlternate) else { return true }
            reportFollowing()
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

/// What the keyboard can do in the sound panel.
enum SoundKey {
    case computer, microphone, previous, next, done
}
