import AppKit
import CursorMonitorKit
import FairyCore
import ScreenshotMonitorKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = FairyState()
    private var panel: FairyPanel!
    private var follower: Follower!
    private var router: DropRouter!
    private var statusItem: NSStatusItem!
    private let notes = NotesController()
    private let summoner = NoteSummoner()

    private var screenshotMonitor: ScreenshotMonitor!
    private var cursorMonitor: CursorMonitor!
    /// Shake discards the top card; shaking on past it discards the rest. Gated off while the
    /// screenshot UI is up (see `ShakeGate`).
    private let shake = ShakeGate()
    private var restTimer: Timer?
    private var hoverGeneration = 0
    private let hoverQueue = DispatchQueue(label: "fairy.hover.ax", qos: .userInitiated)
    /// Notices an interactive screenshot session that ended on screen without the monitor
    /// noticing (see `CaptureWatchdog`).
    private var captureWatchdog = CaptureWatchdog()
    private var watchdogTimer: Timer?
    private let debug = ProcessInfo.processInfo.environment["FAIRY_DEBUG"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        Permissions.requestMissing()

        panel = FairyPanel(state: state)
        follower = Follower(panel: panel)
        router = DropRouter(state: state)
        follower.start()
        startNotes()

        setupStatusItem()
        SystemScreenshotTakeover.shared.applyAtLaunch()
        startScreenshotMonitor()
        startCursorMonitor()

        // Chromium/Electron apps expose web inputs only after an assistive client asks; ask now
        // and for every app launched later, so a double-click in a chat box is recognised at once.
        PasteTarget.prepareRunningApps()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    if PasteTarget.isChromiumLike(app) { PasteTarget.enableWebAccessibilityIfNeeded(pid: app.processIdentifier) }
                }
            }
        }

        if let i = CommandLine.arguments.firstIndex(of: "--demo") {
            let count = i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) ?? 1 : 1
            for k in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.4) { self.loadDemoScreenshot(offset: k) }
            }
        }
        log("ready — accessibility=\(Permissions.accessibility) screenRecording=\(Permissions.screenRecording)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemScreenshotTakeover.shared.restore()
        notes.flush()
        summoner.stop()
        screenshotMonitor?.stop()
        cursorMonitor?.stop()
        follower?.stop()
    }

    // MARK: - Notes

    private func startNotes() {
        notes.carriedScreenshots = { [weak self] in
            guard let state = self?.state, state.isHolding else { return [] }
            return state.deliverable
        }
        notes.onScreenshotsTaken = { [weak self] ids in
            self?.state.deliver(ids: ids, hint: ids.count == 1 ? "added to note" : "added \(ids.count) to note")
        }
        notes.restore()
        summoner.isBlocked = { [weak self] in self?.state.hiddenForCapture ?? false }
        summoner.isOverOwnWindow = { [weak self] point in self?.notes.containsPoint(point) ?? false }
        summoner.onSummon = { [weak self] mouse, origin in
            self?.log("note from \(origin.kind.rawValue): \(origin.label)")
            self?.notes.create(at: mouse, origin: origin)
        }
        summoner.start()
    }

    // MARK: - AUSM monitors

    private func startScreenshotMonitor() {
        var options = ScreenshotMonitor.Options()
        options.writeTempFile = false
        options.debugLogging = debug
        if let bundle = Bundle.main.bundleIdentifier { options.excludedBundleIdentifiers = [bundle] }
        let monitor = ScreenshotMonitor(options: options)
        // The monitor calls back on its private queue. Hop with DispatchQueue.main (strictly FIFO)
        // rather than `Task { @MainActor }`, so started → capture → ended can never be reordered
        // (an "ended" overtaken by its "started" would leave the fairy hidden).
        monitor.onSessionStarted = { [weak self] mode, destination in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.screenshotSessionStarted(mode: mode, destination: destination) }
            }
        }
        monitor.onCapture = { [weak self] capture in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.screenshotCaptured(capture) }
            }
        }
        monitor.onSessionEnded = { [weak self] cancelled in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.screenshotSessionEnded(cancelled: cancelled) }
            }
        }
        monitor.start()
        screenshotMonitor = monitor
    }

    private func screenshotSessionStarted(mode: ScreenshotMonitor.Mode, destination: ScreenshotMonitor.Destination) {
        log("screenshot session started (\(mode.rawValue), \(destination.rawValue))")
        state.hiddenForCapture = true
        // Cursor movement while picking a region or a window is not a shake.
        shake.screenshotUIShown()
        captureWatchdog.sessionStarted(interactive: mode != .screen)
        startWatchdogTimer()
    }

    private func screenshotCaptured(_ capture: ScreenshotMonitor.Capture) {
        log("captured \(capture.image.width)x\(capture.image.height) @\(capture.scale)x mode=\(capture.mode.rawValue)")
        if captureWatchdog.isStale {
            // The screenshot UI had already gone; this "capture" is some later drag the monitor
            // mistook for a selection. Keep it restorable, but don't push it on the pile.
            log("capture from a stale session → kept only for Restore")
            state.stash(image: capture.image, scale: capture.scale, capturedAt: capture.timestamp)
            return
        }
        state.hold(image: capture.image, scale: capture.scale, capturedAt: capture.timestamp)
        shake.captured()
        log("holding \(state.stack.count)")
    }

    private func screenshotSessionEnded(cancelled: Bool) {
        state.hiddenForCapture = false
        shake.screenshotUIGone()
        captureWatchdog.sessionEnded()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if cancelled { log("screenshot session cancelled") }
        // macOS writes its own copy into the private folder shortly after; remove it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { SystemScreenshotTakeover.shared.purge(olderThan: 1) }
        }
    }

    private func startWatchdogTimer() {
        watchdogTimer?.invalidate()
        guard captureWatchdog.isWatching else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self = self, self.captureWatchdog.isWatching else { timer.invalidate(); return }
                let visible = ScreenshotOverlay.isVisible()
                if self.captureWatchdog.observe(overlayVisible: visible, at: CACurrentMediaTime()) {
                    self.log("screenshot UI gone but session still open → showing the fairy again")
                    self.state.hiddenForCapture = false
                    self.shake.screenshotUIGone()
                    timer.invalidate()
                }
            }
        }
    }

    private func startCursorMonitor() {
        var options = CursorMonitor.Options()
        options.moveThrottle = 0                 // every move feeds the shake detector
        options.enrichedActions = ["DOUBLE_CLICK"]
        let monitor = CursorMonitor(options: options)
        monitor.onEvent = { [weak self] event, context in
            // CursorMonitor delivers on the main thread (its tap runs on the main run loop).
            MainActor.assumeIsolated { self?.handleCursorEvent(event, context) }
        }
        if !monitor.start() {
            log("cursor event tap unavailable — grant Accessibility and relaunch")
        }
        cursorMonitor = monitor
    }

    private func handleCursorEvent(_ event: CursorEvent, _ context: CursorContext?) {
        guard event.type == "cursor-event" else { return }
        switch event.action {
        case "MOVE":
            // While the screenshot UI is up the user is aiming a crosshair or picking a window:
            // that movement must never shake off the (invisible) pile.
            guard state.isHolding, !state.hiddenForCapture, let x = event.x, let y = event.y else { return }
            switch shake.move(x: CGFloat(x), y: CGFloat(y), at: CACurrentMediaTime(), holding: state.isHolding) {
            case .discardAll:
                log("long shake → discard all")
                state.discardAll()
                return
            case .discardTop:
                log("shake → discard")
                state.dissolve()
                return
            case .none:
                break
            }
            scheduleHoverHint(at: CGPoint(x: x, y: y))

        case "DOUBLE_CLICK":
            guard state.isHolding else { return }
            // Notes take the pile through their own double-click handler.
            if notes.containsPoint(NSEvent.mouseLocation) { return }
            log("double-click on \(event.bundleId ?? "?") role=\(event.uiElementRole ?? "-") editable=\(event.uiElementIsEditableText.map(String.init) ?? "-")")
            router.handleDoubleClick(event: event, context: context)

        default:
            break
        }
    }

    /// When the cursor rests over something while holding, say what a double-click would do.
    private func scheduleHoverHint(at point: CGPoint) {
        restTimer?.invalidate()
        restTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.state.isHolding, !self.state.hiddenForCapture else { return }
                // Don't query apps while a paste is in flight: the target may be busy asking us
                // for the pasteboard data, and our accessibility calls would stall it.
                guard !self.router.busy else { return }
                if self.notes.containsPoint(NSEvent.mouseLocation) {
                    self.state.setHoverHint("double-click to add to note")
                    return
                }
                self.resolveHover(at: point)
            }
        }
    }

    /// One accessibility lookup at a time; while one runs, only the latest resting point waits.
    private var hoverInFlight = false
    private var pendingHoverPoint: CGPoint?

    private func resolveHover(at point: CGPoint) {
        guard !hoverInFlight else {
            pendingHoverPoint = point
            return
        }
        hoverInFlight = true
        hoverGeneration += 1
        let generation = hoverGeneration
        hoverQueue.async {
            let spot = DropSpotInfo.resolve(at: point)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.applyHover(spot, generation: generation) }
            }
        }
    }

    private func applyHover(_ spot: DropSpotInfo, generation: Int) {
        hoverInFlight = false
        if let next = pendingHoverPoint {
            pendingHoverPoint = nil
            resolveHover(at: next)
            return
        }
        guard generation == hoverGeneration, state.isHolding, !router.busy else { return }
        if let pid = spot.pid, pid != getpid() { router.prepare(pid: pid) }
        if spot.pid == getpid() {
            state.setHoverHint(nil)
        } else if spot.finderDropSpot {
            state.setHoverHint("double-click to save here")
        } else if spot.editable != nil {
            state.setHoverHint("double-click to paste")
        } else {
            state.setHoverHint(nil)
        }
    }

    // MARK: - Status item

    /// The app's glass bead as an 18 pt template glyph: a translucent body, a faint rim and a small
    /// cut-out highlight at the top left. Template, so the menu bar tints it for light/dark.
    static func menuBarDot() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let bead = NSRect(x: 3.25, y: 3.25, width: 11.5, height: 11.5)
            NSColor.black.withAlphaComponent(0.42).setFill()
            NSBezierPath(ovalIn: bead).fill()
            NSColor.black.withAlphaComponent(0.30).setStroke()
            let rim = NSBezierPath(ovalIn: bead.insetBy(dx: 0.4, dy: 0.4))
            rim.lineWidth = 0.6
            rim.stroke()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 5.7, y: 9.5, width: 3.6, height: 2.5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fairy Cursor"
        return image
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.menuBarDot()
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let n = state.deliverable.count
        let status = n == 0 ? "Nothing held — take a screenshot" : (n == 1 ? "Holding 1 screenshot" : "Holding \(n) screenshots")
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        if n > 0 {
            menu.addItem(NSMenuItem(title: "Discard Top Screenshot", action: #selector(discard), keyEquivalent: ""))
            if n > 1 { menu.addItem(NSMenuItem(title: "Discard All", action: #selector(discardAll), keyEquivalent: "")) }
        }
        if state.canRestore {
            menu.addItem(NSMenuItem(title: "Restore Last Screenshot", action: #selector(restoreLast), keyEquivalent: ""))
        }
        menu.addItem(.separator())

        let summon = NSMenuItem(title: "Hold ⌥ on Empty Space for a Note", action: #selector(toggleNoteSummon), keyEquivalent: "")
        summon.state = summoner.isEnabled ? .on : .off
        notes.appendMenuItems(to: menu, summonToggle: summon)
        menu.addItem(.separator())

        let idle = NSMenuItem(title: "Show Fairy When Empty", action: #selector(toggleShowWhenIdle), keyEquivalent: "")
        idle.state = state.showWhenIdle ? .on : .off
        menu.addItem(idle)

        let takeover = NSMenuItem(title: "Replace macOS Screenshot Thumbnail & Auto-Save", action: #selector(toggleTakeover), keyEquivalent: "")
        takeover.state = SystemScreenshotTakeover.shared.isEnabled ? .on : .off
        menu.addItem(takeover)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let ax = NSMenuItem(title: (Permissions.accessibility ? "✓ " : "✗ ") + "Accessibility", action: #selector(openAccessibility), keyEquivalent: "")
        let sr = NSMenuItem(title: (Permissions.screenRecording ? "✓ " : "✗ ") + "Screen Recording", action: #selector(openScreenRecording), keyEquivalent: "")
        menu.addItem(ax)
        menu.addItem(sr)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Fairy Cursor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func discard() { state.dissolve() }
    @objc private func discardAll() { state.discardAll() }
    @objc private func restoreLast() { state.restoreLast() }
    @objc private func toggleNoteSummon() { summoner.isEnabled.toggle() }
    @objc private func toggleShowWhenIdle() { state.showWhenIdle.toggle() }
    @objc private func toggleTakeover() { SystemScreenshotTakeover.shared.setEnabled(!SystemScreenshotTakeover.shared.isEnabled) }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openScreenRecording() { Permissions.openScreenRecordingSettings() }
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            log("launch at login: \(error)")
        }
    }

    private func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts"), !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    // MARK: - Debug

    private func loadDemoScreenshot(offset: Int = 0) {
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        let scale = ScreenCapture.backingScale(of: displayID)
        let sizes = [CGSize(width: 480, height: 300), CGSize(width: 300, height: 360), CGSize(width: 520, height: 200)]
        let size = sizes[offset % sizes.count]
        let rect = CGRect(x: bounds.midX - size.width / 2 + CGFloat(offset) * 120, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        ScreenCapture.captureDisplay(displayID, cropTo: rect, excluding: ScreenCapture.Exclusions()) { image, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let image = image else { return }
                    self.state.hold(image: image, scale: scale)
                }
            }
        }
    }

    private func log(_ message: String) {
        if debug { NSLog("[FairyCursor] \(message)") }
    }
}

/// Whether the system screenshot UI's selection overlay is on screen: a large window owned by
/// `screencaptureui` (the floating thumbnail and the ⌘⇧5 toolbar are small and don't count).
/// Reads only window bounds and owners, which need no Screen Recording permission.
enum ScreenshotOverlay {
    static func isVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let displays = NSScreen.screens.map { $0.frame.width * $0.frame.height }
        let smallestDisplay = displays.min() ?? 0
        return list.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, isScreenshotUI(pid: pid, owner: info[kCGWindowOwnerName as String] as? String),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return false }
            return smallestDisplay > 0 && bounds.width * bounds.height >= 0.4 * smallestDisplay
        }
    }

    private static func isScreenshotUI(pid: pid_t, owner: String?) -> Bool {
        if owner?.lowercased() == "screencaptureui" { return true }
        let app = NSRunningApplication(processIdentifier: pid)
        return app?.bundleIdentifier == "com.apple.screencaptureui" || app?.executableURL?.lastPathComponent == "screencaptureui"
    }
}
