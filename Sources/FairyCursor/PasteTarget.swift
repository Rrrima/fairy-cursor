import AppKit
@preconcurrency import ApplicationServices
import CursorMonitorKit
import FairyCore

/// Delivers the held screenshot into a text input: put the image on the pasteboard, press ⌘V,
/// learn whether the app took it, then put the user's previous clipboard back.
@MainActor
enum PasteTarget {
    /// Chromium-based browsers and Electron apps only build their web accessibility tree once an
    /// assistive client announces itself. Without it, inputs inside web pages are invisible to
    /// hit-testing, so we turn it on for the app under the cursor (once per app).
    nonisolated(unsafe) private static var axEnabledPIDs: Set<pid_t> = []
    nonisolated private static let axEnabledLock = NSLock()

    nonisolated static func enableWebAccessibilityIfNeeded(pid: pid_t) {
        let isNew = axEnabledLock.withLock { axEnabledPIDs.insert(pid).inserted }
        guard isNew else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanTrue)
        }
    }

    /// Flip the switch for every Chromium-like app that is already running (and call again from
    /// a launch observer for new ones). Chrome takes ~2 s to build its tree, so this has to happen
    /// well before the first double-click.
    static func prepareRunningApps() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if isChromiumLike(app) { enableWebAccessibilityIfNeeded(pid: app.processIdentifier) }
        }
    }

    nonisolated static func isChromiumLike(_ app: NSRunningApplication) -> Bool {
        let bundle = app.bundleIdentifier ?? ""
        let chromiumPrefixes = ["com.google.Chrome", "com.brave.", "com.microsoft.edgemac", "company.thebrowser",
                                "com.vivaldi", "org.chromium", "com.operasoftware"]
        if chromiumPrefixes.contains(where: { bundle.hasPrefix($0) }) { return true }
        // Electron / CEF apps ship the framework inside the bundle.
        guard let url = app.bundleURL else { return false }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) {
            return names.contains { $0.hasPrefix("Electron Framework") || $0.hasPrefix("Chromium Embedded Framework") }
        }
        return false
    }

    /// Terminal emulators paste text only, so for them the screenshot is written to disk and its
    /// path is pasted (Claude Code and most CLIs read image files from a path).
    private static let terminalBundleIDs: Set<String> = [
        "com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.mitchellh.ghostty", "co.zeit.hyper", "com.termius-dmg.mac", "app.tabby",
    ]

    static func isTerminal(pid: pid_t?) -> Bool {
        guard let pid = pid, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(bundle)
    }

    /// Folder where screenshots pasted into terminals are kept (they must outlive the paste).
    static let pastedFolder: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appendingPathComponent("Fairy Cursor", isDirectory: true)
    }()

    enum Delivery {
        case image, path(URL)
        var isPath: Bool { if case .path = self { return true } else { return false } }
    }

    enum Outcome {
        case accepted(Delivery)
        /// ⌘V went through but the field showed no change: it does not take images (e.g. a search box).
        case rejected
        case failed
    }

    /// A fingerprint of the target field taken before ⌘V, compared afterwards to learn whether
    /// the paste was accepted. Rich text views reveal attachments as U+FFFC in their value; web
    /// composers add an image node (inline or as an attachment chip) near the field; terminals
    /// and plain fields change their text.
    struct AcceptanceProbe: @unchecked Sendable {
        struct Signature: Equatable {
            let characters: Int
            let valueHash: Int
            let images: Int
        }

        let element: AXUIElement
        let container: AXUIElement
        let before: Signature
        /// Multi-line composers (chat boxes, documents) show image attachments where the probe
        /// cannot see them (Slack), so only single-line fields are verified by the probe.
        let isMultiline: Bool

        init?(element: AXUIElement?) {
            guard let element = element else { return nil }
            self.element = element
            // The nearest ancestors host attachment previews in chat composers.
            var container = element
            for _ in 0..<5 {
                var parent: AnyObject?
                guard AXUIElementCopyAttributeValue(container, kAXParentAttribute as CFString, &parent) == .success,
                      let next = parent else { break }
                let role = axStringAttribute(next as! AXUIElement, kAXRoleAttribute) ?? ""
                if role == kAXWindowRole || role == "AXWebArea" || role == kAXApplicationRole { break }
                container = next as! AXUIElement
            }
            self.container = container
            self.before = Self.signature(element: element, container: container)
            self.isMultiline = axStringAttribute(element, kAXRoleAttribute) == kAXTextAreaRole
        }

        func changed() -> Bool {
            return Self.signature(element: element, container: container) != before
        }

        private static func signature(element: AXUIElement, container: AXUIElement) -> Signature {
            var value: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
            let text = (value as? String) ?? ""
            var count: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count)
            let characters = (count as? Int) ?? text.count
            return Signature(characters: characters, valueHash: String(text.prefix(4000)).hashValue, images: imageCount(under: container))
        }

        private static func imageCount(under root: AXUIElement) -> Int {
            var images = 0
            var visited = 0
            func walk(_ node: AXUIElement, _ depth: Int) {
                if depth > 9 || visited > 1500 { return }
                visited += 1
                if axStringAttribute(node, kAXRoleAttribute) == kAXImageRole { images += 1 }
                var children: AnyObject?
                guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
                      let list = children as? [AXUIElement] else { return }
                for child in list { walk(child, depth + 1) }
            }
            walk(root, 0)
            return images
        }
    }

    nonisolated static let probeQueue = DispatchQueue(label: "fairy.paste-probe", qos: .userInitiated)

    /// - Parameters:
    ///   - collapseSelection: press → first (a fresh double-click selected a word); later pastes in
    ///     a pile already have the caret after the previous image.
    ///   - verify: probe single-line fields to learn whether the image was taken; later pastes in
    ///     a pile skip it, since the first one already proved the field takes images.
    ///   - clipboard: the user's clipboard to restore afterwards; a pile passes the copy taken
    ///     before its first paste, so the screenshots never end up as "your" clipboard.
    static func paste(_ screenshot: HeldScreenshot, to pid: pid_t?, element: AXUIElement?,
                      collapseSelection: Bool = true, verify: Bool = true,
                      clipboard: PasteboardSnapshot? = nil,
                      completion: @escaping (Outcome) -> Void) {
        let job = PasteJob(screenshot: screenshot, pid: pid, element: element, collapseSelection: collapseSelection,
                           verify: verify, snapshot: clipboard ?? PasteboardSnapshot(NSPasteboard.general),
                           completion: completion)
        job.start()
    }
}

/// One paste, run as a small state machine on the main thread (decisions in `PastePolicy`):
///  1. wait for the double-click's mouse-up (focus and word selection are final);
///  2. bring the target app to the front if it is not;
///  3. collapse the selection (→), write the pasteboard (image data promised lazily, so reads are
///     observable), press ⌘V through the session event stream;
///  4. decide the outcome from pasteboard reads (and the probe for single-line fields);
///  5. restore the user's clipboard once the target has finished reading.
@MainActor
final class PasteJob {
    private static var running: [ObjectIdentifier: PasteJob] = [:]

    private let screenshot: HeldScreenshot
    private let pid: pid_t?
    private let element: AXUIElement?
    private let collapseSelection: Bool
    private let verify: Bool
    private let snapshot: PasteboardSnapshot
    private var completion: ((PasteTarget.Outcome) -> Void)?

    private var terminal = false
    private var delivery = PasteTarget.Delivery.image
    private var promise: PromisedPasteboardItem?
    private var probe: PasteTarget.AcceptanceProbe?
    private var probeReady = false
    private var probeChanged = false
    private var probeCheckInFlight = false
    private var lastProbeCheck: CFTimeInterval = 0
    private var changeCount = 0
    private var sentAt: CFTimeInterval = 0
    private var restoreDone = false

    init(screenshot: HeldScreenshot, pid: pid_t?, element: AXUIElement?, collapseSelection: Bool, verify: Bool,
         snapshot: PasteboardSnapshot, completion: @escaping (PasteTarget.Outcome) -> Void) {
        self.screenshot = screenshot
        self.pid = pid
        self.element = element
        self.collapseSelection = collapseSelection
        self.verify = verify
        self.snapshot = snapshot
        self.completion = completion
    }

    private var now: CFTimeInterval { CACurrentMediaTime() }
    /// The app that receives typing: the accessibility "focused application", which also covers
    /// non-activating panels (e.g. a chat app's floating launcher window is key while the app is
    /// not "frontmost"); falls back to the frontmost app.
    private var frontmostPID: pid_t? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var ref: AnyObject?
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &ref) == .success,
           let ref = ref, CFGetTypeID(ref) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(ref as! AXUIElement, &pid) == .success, pid > 0 { return pid }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func start() {
        guard let png = screenshot.pngData(), let tiff = screenshot.tiffData() else {
            finish(.failed)
            return
        }
        terminal = PasteTarget.isTerminal(pid: pid)
        var payload: [NSPasteboard.PasteboardType: Data] = [.png: png, .tiff: tiff]
        if terminal {
            try? FileManager.default.createDirectory(at: PasteTarget.pastedFolder, withIntermediateDirectories: true)
            guard let url = FinderTarget.save(screenshot, into: PasteTarget.pastedFolder) else {
                finish(.failed)
                return
            }
            delivery = .path(url)
            payload[.string] = Data(PastePolicy.shellQuoted(url.path).utf8)
            payload[.fileURL] = Data(url.absoluteString.utf8)
        }
        promise = PromisedPasteboardItem(payload: payload)
        Self.running[ObjectIdentifier(self)] = self

        // The probe walks the accessibility tree of the target: build it off the main thread
        // while we wait for the mouse-up.
        if verify, !terminal {
            let pid = self.pid, element = self.element
            PasteTarget.probeQueue.async {
                let focused = pid.flatMap { AXNode.focused(in: $0)?.element }
                let probe = PasteTarget.AcceptanceProbe(element: focused ?? element)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.probe = probe
                        self.probeReady = true
                    }
                }
            }
        } else {
            probeReady = true
        }
        waitForMouseUp(since: now)
    }

    private func waitForMouseUp(since start: CFTimeInterval) {
        let elapsed = now - start
        let step = PastePolicy.mouseUpStep(elapsed: elapsed, buttonsDown: NSEvent.pressedMouseButtons != 0)
        if step == .wait || (!probeReady && elapsed < PastePolicy.mouseUpTimeout) {
            after(PastePolicy.mouseUpPollInterval) { self.waitForMouseUp(since: start) }
            return
        }
        after(PastePolicy.afterMouseUpDelay) { self.bringTargetForward(since: self.now, asked: false) }
    }

    private func bringTargetForward(since start: CFTimeInterval, asked: Bool) {
        guard PastePolicy.needsActivation(target: pid, frontmost: frontmostPID), now - start < PastePolicy.activationTimeout,
              let pid = pid, let app = NSRunningApplication(processIdentifier: pid) else {
            collapseAndPaste()
            return
        }
        if !asked {
            NSLog("[FairyCursor] paste: activating target pid=%d (front pid=%d)", pid, frontmostPID ?? -1)
            app.activate()
        }
        after(0.03) { self.bringTargetForward(since: start, asked: true) }
    }

    private func collapseAndPaste() {
        let route = PastePolicy.keyRoute(target: pid, frontmost: frontmostPID)
        // In a shell, → can accept an autosuggestion, so skip it for terminals.
        if !terminal && collapseSelection { Keys.press(Keys.rightArrow, route: route) }
        after(PastePolicy.collapseToPasteDelay) {
            // Write the pasteboard only now: terminals with copy-on-select (iTerm) copy the
            // double-clicked word on mouse-up, which would replace an earlier write.
            guard let promise = self.promise else { return }
            self.changeCount = promise.write(to: NSPasteboard.general)
            let route = PastePolicy.keyRoute(target: self.pid, frontmost: self.frontmostPID)
            Keys.press(Keys.v, command: true, route: route)
            self.sentAt = self.now
            NSLog("[FairyCursor] paste: sent ⌘V via %@ (target pid %d, %@)",
                  route == .session ? "session" : "pid", self.pid ?? -1, self.terminal ? "path" : "image")
            self.pollOutcome()
            self.pollRestore()
        }
    }

    private func pollOutcome() {
        guard completion != nil, let promise = promise else { return }
        let hasProbe = probe.map { !$0.isMultiline } ?? false
        let rules = PastePolicy.OutcomeRules(hasProbe: hasProbe)
        let elapsed = now - sentAt
        switch rules.evaluate(elapsed: elapsed, reads: promise.reads, probeChanged: probeChanged) {
        case .accepted:
            NSLog("[FairyCursor] paste: accepted (reads=%d probe=%@)", promise.reads, probeChanged ? "changed" : "-")
            finish(.accepted(delivery))
        case .rejected:
            NSLog("[FairyCursor] paste: field unchanged → rejected")
            finish(.rejected)
        case .failed:
            NSLog("[FairyCursor] paste: nothing read the pasteboard → failed")
            finish(.failed)
        case .pending:
            if hasProbe, let probe = probe, !probeCheckInFlight, now - lastProbeCheck >= 0.2 {
                probeCheckInFlight = true
                lastProbeCheck = now
                PasteTarget.probeQueue.async {
                    let changed = probe.changed()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.probeCheckInFlight = false
                            if changed { self.probeChanged = true }
                        }
                    }
                }
            }
            after(0.05) { self.pollOutcome() }
        }
    }

    private func pollRestore() {
        guard let promise = promise else { return }
        let pasteboard = NSPasteboard.general
        let rules = PastePolicy.RestoreRules()
        let step = rules.step(sinceSend: now - sentAt,
                              sinceLastRead: promise.lastReadAt.map { now - $0 },
                              pasteboardUnchanged: pasteboard.changeCount == changeCount)
        switch step {
        case .wait:
            after(0.1) { self.pollRestore() }
        case .restore:
            snapshot.restore(to: pasteboard)
            restoreDone = true
            cleanUp()
        case .abandon:
            restoreDone = true
            cleanUp()
        }
    }

    private func finish(_ outcome: PasteTarget.Outcome) {
        guard let completion = completion else { return }
        self.completion = nil
        completion(outcome)
        cleanUp()
    }

    private func cleanUp() {
        // Stay alive until both the outcome is reported and the clipboard is settled.
        if completion == nil && (restoreDone || sentAt == 0) {
            promise = nil
            Self.running[ObjectIdentifier(self)] = nil
        }
    }

    private func after(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
    }
}

/// A pasteboard item whose data is promised rather than written, so we learn when (and whether)
/// another app actually reads it. Called back on the main thread by AppKit.
final class PromisedPasteboardItem: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let payload: [NSPasteboard.PasteboardType: Data]
    private(set) var reads = 0
    private(set) var lastReadAt: CFTimeInterval?

    init(payload: [NSPasteboard.PasteboardType: Data]) {
        self.payload = payload
    }

    /// Clear the general pasteboard and put this item on it. Returns the new change count.
    func write(to pasteboard: NSPasteboard) -> Int {
        let item = NSPasteboardItem()
        // Text first for terminals (they read the first type they understand), then images.
        let order: [NSPasteboard.PasteboardType] = [.string, .fileURL, .png, .tiff]
        item.setDataProvider(self, forTypes: order.filter { payload[$0] != nil })
        for marker in PastePolicy.transientMarkerTypes {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        if let bundle = Bundle.main.bundleIdentifier {
            item.setString(bundle, forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = payload[type] else { return }
        item.setData(data, forType: type)
        reads += 1
        lastReadAt = CACurrentMediaTime()
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

/// Copy of the general pasteboard's items for the common data types, so the screenshot paste
/// doesn't clobber what the user had copied.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    private static let types: [NSPasteboard.PasteboardType] = [
        .string, .rtf, .rtfd, .html, .png, .tiff, .pdf, .fileURL, .URL,
    ]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in Self.types where item.types.contains(type) {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }.filter { !$0.isEmpty }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
