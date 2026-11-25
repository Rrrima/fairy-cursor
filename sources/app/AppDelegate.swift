import AppKit
import CursorMonitorKit
import FairyCore
import FairyKit
import SwiftUI

/// The host: the fairy itself (it follows the cursor, carries screenshots, shakes them off and
/// drops them into apps and folders) plus the menu and Settings. Everything else it can do comes
/// from capabilities (see `CapabilityRegistry`), which reach it only through `FairyHost`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = FairyState()
    private var panel: FairyPanel!
    private var follower: Follower!
    private var router: DropRouter!
    private var statusItem: NSStatusItem!
    private let settings = AppSettings.shared
    private let capabilities = CapabilityRegistry()
    private lazy var settingsWindow = SettingsWindowController(model: SettingsModel(capabilities: capabilities))
    private lazy var guideWindow = GuideWindowController(capabilities: capabilities)

    private var cursorMonitor: CursorMonitor!
    /// Shake discards the top card; shaking on past it discards the rest. Gated off while the
    /// screenshot UI is up (see `ShakeGate`).
    private let shake = ShakeGate()
    private var restTimer: Timer?
    private var hoverGeneration = 0
    private let hoverQueue = DispatchQueue(label: "fairy.hover.ax", qos: .userInitiated)

    // What capabilities have set up through `FairyHost`, by owner.
    private var captureUIOwners: Set<String> = []
    private var exclusiveOwners: Set<String> = []
    private var dropZones: [String: DropZone] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        // A download opened where it landed moves itself into Applications and starts again.
        if Relocation.moveToApplicationsIfNeeded() { return }

        panel = FairyPanel(state: state)
        follower = Follower(panel: panel)
        router = DropRouter(state: state)
        follower.start()

        setupStatusItem()
        capabilities.onDeactivated = { [weak self] id in self?.release(owner: id) }
        // Nothing asks macOS for anything by itself: the guide does, one permission at a time,
        // when its buttons are pressed. Watching the cursor and keys would each raise a system
        // dialog of their own, so that waits until Accessibility is allowed.
        if Permissions.accessibility { startWatching() } else { waitForAccessibility() }
        guideWindow.showOnLaunchIfNeeded()
        log("ready — accessibility=\(Permissions.accessibility) screenRecording=\(Permissions.screenRecording)")
    }

    private func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard Permissions.accessibility else { return }
                timer.invalidate()
                self?.log("accessibility allowed")
                self?.startWatching()
            }
        }
    }

    /// Everything that listens to the cursor, the keys and other apps.
    private func startWatching() {
        startCursorMonitor()
        capabilities.start(host: self)

        // Chromium/Electron apps expose web inputs only after an assistive client asks; ask now
        // and for every app launched later, so a double-click in a chat box is recognised at once.
        WebAccessibility.prepareRunningApps()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    if WebAccessibility.isChromiumLike(app) { WebAccessibility.enableWebAccessibilityIfNeeded(pid: app.processIdentifier) }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capabilities.stopAll()
        cursorMonitor?.stop()
        follower?.stop()
    }

    /// A capability was switched off: undo what it had set (a hidden fairy, a held screen, a drop zone).
    private func release(owner: String) {
        setCaptureUIVisible(false, owner: owner)
        setExclusive(false, owner: owner)
        setDropZone(nil, owner: owner)
    }

    private func dropZone(at point: CGPoint) -> DropZone? {
        dropZones.values.first { $0.contains(point) }
    }

    // MARK: - Cursor

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

        case "CLICK":
            // Remember the clipboard before a possible double-click: a terminal copies the
            // clicked word on mouse-up, and that must not be taken for the user's clipboard.
            guard state.isHolding else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { PasteTarget.rememberClipboard() } }

        case "DOUBLE_CLICK":
            guard state.isHolding else { return }
            // A capability's window (a note) takes the pile through its own double-click handler.
            if dropZone(at: NSEvent.mouseLocation) != nil { return }
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
                if let zone = self.dropZone(at: NSEvent.mouseLocation) {
                    self.state.setHoverHint(zone.hint)
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
        } else if spot.editable != nil || spot.canvas {
            state.setHoverHint("double-click to paste")
        } else {
            state.setHoverHint(nil)
        }
    }

    // MARK: - Status item

    /// The app's mark (`LogoMark`) as a menu-bar-height template glyph, so the menu bar tints it for
    /// light and dark.
    static func menuBarGlyph() -> NSImage {
        // Full height, width hugging the mark: the status item adds its own spacing around it.
        let mark = LogoMark.outline().boundingBoxOfPath
        let height: CGFloat = 17
        let width = (height * mark.width / mark.height).rounded(.up)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(LogoMark.path(fitting: CGRect(x: 0, y: 0, width: width, height: height), yUp: true))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Fairy Cursor"
        return image
    }

    private func setupStatusItem() {
        let glyph = Self.menuBarGlyph()
        // Hugs the mark with a hair of room: `variableLength` adds wide side margins.
        statusItem = NSStatusBar.system.statusItem(withLength: glyph.size.width + 2)
        if let button = statusItem.button {
            button.image = glyph
            button.imagePosition = .imageOnly
        }
        let menu = NSMenu()
        // Items say for themselves whether they're enabled (a status line, "Saving Recording…").
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let held = state.deliverable
        let n = held.count
        // When every held screenshot is already saved, letting go doesn't delete anything.
        let kept = n > 0 && held.allSatisfy(\.kept)
        let status = n == 0 ? "Nothing held" : (n == 1 ? "Holding 1 screenshot" : "Holding \(n) screenshots")
        menu.addItem(ActionMenuItem(status, enabled: false) {})
        if n > 0 {
            menu.addItem(ActionMenuItem(kept ? "Let Go of Top Screenshot" : "Discard Top Screenshot") { [weak self] in self?.state.dissolve() })
            if n > 1 { menu.addItem(ActionMenuItem(kept ? "Let Go of All" : "Discard All") { [weak self] in self?.state.discardAll() }) }
        }
        if state.canRestore {
            menu.addItem(ActionMenuItem("Restore Last Screenshot") { [weak self] in self?.state.restoreLast() })
        }

        // Each enabled capability's items, in their own group.
        for capability in capabilities.enabled {
            let items = capability.menuItems()
            guard !items.isEmpty else { continue }
            menu.addItem(.separator())
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())

        // Only shown when something needs doing; otherwise permissions live in Settings.
        for permission in Permission.allCases where capabilities.neededPermissions.contains(permission) && !permission.isGranted {
            menu.addItem(ActionMenuItem("Allow \(permission.title)…") { Permissions.allow(permission) })
        }
        menu.addItem(ActionMenuItem("Welcome Guide…") { [weak self] in self?.guideWindow.show() })
        menu.addItem(ActionMenuItem("Settings…") { [weak self] in self?.settingsWindow.show() })
        menu.addItem(NSMenuItem(title: "Quit Fairy Cursor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts"), !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    private func log(_ message: String) {
        FairyLog.write(message)
    }
}

// MARK: - FairyHost

extension AppDelegate: FairyHost {
    func carry(_ image: CGImage, scale: CGFloat, capturedAt: Date, kept: Bool) {
        state.hold(image: image, scale: scale, capturedAt: capturedAt, kept: kept)
        shake.captured()
        log("holding \(state.stack.count)")
    }

    func carry(recording url: URL, poster: CGImage, scale: CGFloat, duration: TimeInterval) {
        state.hold(image: poster, scale: scale, kept: true, movie: url, duration: duration)
        shake.captured()
        log("holding \(state.stack.count) (recording)")
    }

    func keepForRestore(_ image: CGImage, scale: CGFloat, capturedAt: Date) {
        state.stash(image: image, scale: scale, capturedAt: capturedAt)
    }

    var carried: [HeldScreenshot] { state.isHolding ? state.deliverable : [] }

    func delivered(_ ids: [UUID], hint: String) {
        state.deliver(ids: ids, hint: hint)
    }

    func setCaptureUIVisible(_ visible: Bool, owner: String) {
        let wasVisible = !captureUIOwners.isEmpty
        if visible { captureUIOwners.insert(owner) } else { captureUIOwners.remove(owner) }
        let isVisible = !captureUIOwners.isEmpty
        guard isVisible != wasVisible else { return }
        state.hiddenForCapture = isVisible
        // Cursor movement while picking a region or a window is not a shake.
        if isVisible { shake.screenshotUIShown() } else { shake.screenshotUIGone() }
    }

    func setExclusive(_ on: Bool, owner: String) {
        if on { exclusiveOwners.insert(owner) } else { exclusiveOwners.remove(owner) }
    }

    var isScreenBusy: Bool { !captureUIOwners.isEmpty || !exclusiveOwners.isEmpty }

    func setDropZone(_ zone: DropZone?, owner: String) {
        dropZones[owner] = zone
    }

    var capturesFolder: URL { settings.capturesFolder }
}
