import AppKit

/// Hold ⌥ on its own over empty space (Desktop, page margin, window background) and a glass pill
/// rings the cursor; click while it shows and a note grows out of it. The click is swallowed so
/// the app underneath never sees an ⌥-click.
@MainActor
final class NoteSummoner {
    var isEnabled: Bool = UserDefaults.standard.object(forKey: "noteSummonEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "noteSummonEnabled")
            if !isEnabled { endHold() }
        }
    }
    /// True while something else owns the screen (the system screenshot UI).
    var isBlocked: () -> Bool = { false }
    /// Is this point (AppKit coordinates) over one of our notes?
    var isOverOwnWindow: (CGPoint) -> Bool = { _ in false }
    /// Make a note: click location in AppKit coordinates, and where it was started.
    var onSummon: ((CGPoint, NoteOrigin) -> Void)?

    /// ⌥ must be held this long first, so ⌥-shortcuts and quick taps never flash the pill.
    private let holdDelay: TimeInterval = 0.3
    private let panel = SummonPanel()
    private var monitors: [Any] = []
    private var armTimer: Timer?
    private var trackTimer: Timer?
    private var optionDown = false
    /// This hold is used up: a key was typed, a mouse button was down, or a note was made.
    private var spent = false
    private var spotIsEmpty = false
    private var lastCheck: CFTimeInterval = 0
    private var tap: CFMachPort?
    private var swallowingClick = false

    func start() {
        let flags: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event.modifierFlags) }
        }
        let keys: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.keyTyped() }
        }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys),
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keys($0); return $0 },
        ].compactMap { $0 }
        installClickTap()
    }

    func stop() {
        endHold()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    // MARK: - ⌥ hold

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let onlyOption = flags.intersection([.command, .option, .control, .shift]) == .option
        if onlyOption, !optionDown {
            NoteLog.write("⌥ down")
            optionDown = true
            spent = NSEvent.pressedMouseButtons != 0     // ⌥-drag already under way
            armTimer?.invalidate()
            armTimer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginTracking() }
            }
        } else if !onlyOption, optionDown {
            optionDown = false
            endHold()
        }
    }

    private func keyTyped() {
        guard optionDown else { return }
        spent = true
        hidePill()
    }

    private func beginTracking() {
        NoteLog.write("hold: down=\(optionDown) spent=\(spent) enabled=\(isEnabled) blocked=\(isBlocked()) buttons=\(NSEvent.pressedMouseButtons) trusted=\(AXIsProcessTrusted()) tap=\(tap != nil)")
        guard optionDown, !spent, isEnabled, !isBlocked(), NSEvent.pressedMouseButtons == 0 else { return }
        // Without Accessibility the spot can't be read and the click can't be caught, so the pill
        // would promise a note it cannot make. A grant made while running is picked up here.
        guard AXIsProcessTrusted() else { return }
        if tap == nil { installClickTap() }
        guard tap != nil else { return }
        lastCheck = 0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
        track()
    }

    private func track() {
        guard !spent, !isBlocked() else { hidePill(); return }
        let mouse = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        if now - lastCheck > 0.12 {
            lastCheck = now
            let wasEmpty = spotIsEmpty
            spotIsEmpty = !isOverOwnWindow(mouse) && NoteContext.isEmptySpot(at: Self.cgPoint(mouse), previous: spotIsEmpty)
            if spotIsEmpty != wasEmpty || !spotIsEmpty { NoteLog.write("spot empty=\(spotIsEmpty) \(NoteContext.describe(at: Self.cgPoint(mouse)))") }
        }
        if spotIsEmpty {
            if !panel.model.visible { NoteLog.write("pill shown at \(Int(mouse.x)),\(Int(mouse.y)) tap=\(tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)") }
            panel.show(at: mouse)
        } else {
            hidePill()
        }
    }

    private func hidePill() {
        panel.hide()
    }

    private func endHold() {
        armTimer?.invalidate()
        armTimer = nil
        trackTimer?.invalidate()
        trackTimer = nil
        spotIsEmpty = false
        hidePill()
    }

    /// AppKit (bottom-left origin) → global CG (top-left origin of the primary display).
    private static func cgPoint(_ p: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    // MARK: - Click

    /// An active event tap that takes the click for itself while the pill shows and passes every
    /// other click straight through.
    private func installClickTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let summoner = Unmanaged<NoteSummoner>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { summoner.handleTap(type: type, event: event) }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NoteLog.write("click tap unavailable (accessibility=\(AXIsProcessTrusted()))")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        NoteLog.write("click tap ready (accessibility=\(AXIsProcessTrusted()))")
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            NoteLog.write("click tap disabled by system (\(type.rawValue)); re-enabling")
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown where panel.model.visible:
            NoteLog.write("click on pill → new note")
            swallowingClick = true
            spent = true
            let mouse = NSEvent.mouseLocation
            let point = event.location
            panel.hide(animated: false)
            // Off the tap callback: reading the origin can take a moment (AX, AppleScript).
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onSummon?(mouse, NoteContext.origin(at: point)) }
            }
            return nil
        case .leftMouseDragged where swallowingClick:
            return nil
        case .leftMouseUp where swallowingClick:
            swallowingClick = false
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

/// Append-only trace of the note gesture at ~/Library/Logs/Fairy Cursor Notes.log.
enum NoteLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Fairy Cursor Notes.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
