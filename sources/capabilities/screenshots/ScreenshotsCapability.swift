import AppKit
import FairyCore
import FairyKit
import ScreenshotMonitorKit
import SwiftUI

/// Take a screenshot with ⌘⇧3, ⌘⇧4 or ⌘⇧5 and the fairy carries it, instead of a thumbnail in
/// the corner and a file on the Desktop. Built on ausm's ScreenshotMonitorKit.
@MainActor
public final class ScreenshotsCapability: Capability {
    public static let manifest = CapabilityManifest(
        id: "fairy.screenshots",
        name: "Screenshots",
        summary: "⌘⇧3, ⌘⇧4 or ⌘⇧5, and the fairy carries the shot.",
        permissions: [.screenRecording],
        shortcuts: ["⌘⇧3", "⌘⇧4", "⌘⇧5"]
    )

    private weak var host: FairyHost?
    private var monitor: ScreenshotMonitor?
    private let settings = ScreenshotSettings.shared
    /// Notices an interactive screenshot session that ended on screen without the monitor
    /// noticing (see `CaptureWatchdog`).
    private var watchdog = CaptureWatchdog()
    private var watchdogTimer: Timer?
    private var id: String { Self.manifest.id }

    public init() {}

    public func activate(host: FairyHost) {
        self.host = host
        SystemScreenshotTakeover.shared.activate()
        startMonitor()
        if let i = CommandLine.arguments.firstIndex(of: "--demo") {
            let count = i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) ?? 1 : 1
            for k in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.4) { self.loadDemoScreenshot(offset: k) }
            }
        }
    }

    public func deactivate() {
        monitor?.stop()
        monitor = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        watchdog.sessionEnded()
        SystemScreenshotTakeover.shared.restore()
        host = nil
    }

    public func menuItems() -> [NSMenuItem] {
        guard settings.keep else { return [] }
        return [ActionMenuItem("Open Screenshots Folder") { [weak self] in
            guard let folder = self?.host?.capturesFolder else { return }
            Folders.open(folder)
        }]
    }

    public func settingsView() -> AnyView? {
        AnyView(ScreenshotSettingsRows(settings: settings))
    }

    // MARK: - Monitor

    private func startMonitor() {
        var options = ScreenshotMonitor.Options()
        options.writeTempFile = false
        // Only ⌘⇧3/4/5: ignore other programs running `screencapture` in the background.
        options.hotkeyOnly = true
        options.debugLogging = FairyLog.enabled
        if let bundle = Bundle.main.bundleIdentifier { options.excludedBundleIdentifiers = [bundle] }
        let monitor = ScreenshotMonitor(options: options)
        // The monitor calls back on its private queue. Hop with DispatchQueue.main (strictly FIFO)
        // rather than `Task { @MainActor }`, so started → capture → ended can never be reordered
        // (an "ended" overtaken by its "started" would leave the fairy hidden).
        monitor.onSessionStarted = { [weak self] mode, destination in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sessionStarted(mode: mode, destination: destination) }
            }
        }
        monitor.onCapture = { [weak self] capture in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.captured(capture) }
            }
        }
        monitor.onSessionEnded = { [weak self] cancelled in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sessionEnded(cancelled: cancelled) }
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    private func sessionStarted(mode: ScreenshotMonitor.Mode, destination: ScreenshotMonitor.Destination) {
        guard let host = host else { return }
        FairyLog.write("screenshot session started (\(mode.rawValue), \(destination.rawValue))")
        host.setCaptureUIVisible(true, owner: id)
        watchdog.sessionStarted(interactive: mode != .screen)
        startWatchdogTimer()
    }

    private func captured(_ capture: ScreenshotMonitor.Capture) {
        guard let host = host else { return }
        FairyLog.write("captured \(capture.image.width)x\(capture.image.height) @\(capture.scale)x mode=\(capture.mode.rawValue)")
        if watchdog.isStale {
            // The screenshot UI had already gone; this "capture" is some later drag the monitor
            // mistook for a selection. Keep it restorable, but don't push it on the pile.
            FairyLog.write("capture from a stale session → kept only for Restore")
            host.keepForRestore(capture.image, scale: capture.scale, capturedAt: capture.timestamp)
            return
        }
        let kept = settings.keep
        if kept { ScreenshotSaver.save(capture.image, scale: capture.scale, takenAt: capture.timestamp, in: host.capturesFolder) }
        host.carry(capture.image, scale: capture.scale, capturedAt: capture.timestamp, kept: kept)
    }

    private func sessionEnded(cancelled: Bool) {
        host?.setCaptureUIVisible(false, owner: id)
        watchdog.sessionEnded()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if cancelled { FairyLog.write("screenshot session cancelled") }
        // macOS writes its own copy into the private folder shortly after; remove it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { SystemScreenshotTakeover.shared.purge(olderThan: 1) }
        }
    }

    private func startWatchdogTimer() {
        watchdogTimer?.invalidate()
        guard watchdog.isWatching else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self = self, self.watchdog.isWatching else { timer.invalidate(); return }
                if self.watchdog.observe(overlayVisible: ScreenshotOverlay.isVisible(), at: CACurrentMediaTime()) {
                    FairyLog.write("screenshot UI gone but session still open → showing the fairy again")
                    self.host?.setCaptureUIVisible(false, owner: self.id)
                    timer.invalidate()
                }
            }
        }
    }

    // MARK: - Debug

    /// `--demo [n]`: put n crops of the main display on the pile at launch.
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
                    self.host?.carry(image, scale: scale, capturedAt: Date(), kept: false)
                }
            }
        }
    }
}

/// Whether to keep every screenshot. Stored in UserDefaults under the key it always had.
@MainActor
final class ScreenshotSettings: ObservableObject {
    static let shared = ScreenshotSettings()

    /// On: every screenshot is saved as it's taken, and shaking only lets go of it.
    /// Off: nothing is saved unless you drop it somewhere; shaking throws it away.
    @Published var keep: Bool {
        didSet { UserDefaults.standard.set(keep, forKey: "screenshots.keep") }
    }

    private init() {
        keep = UserDefaults.standard.object(forKey: "screenshots.keep") as? Bool ?? false
    }
}

private struct ScreenshotSettingsRows: View {
    @ObservedObject var settings: ScreenshotSettings

    var body: some View {
        ToggleRow(
            title: "Keep every screenshot",
            detail: settings.keep
                ? "Each one is saved to your captures folder as you take it. Shaking only lets go of it."
                : "Nothing is saved unless you drop it somewhere. Shaking throws it away.",
            isOn: $settings.keep
        )
    }
}

/// Whether the system screenshot UI's selection overlay is on screen: a large window owned by
/// `screencaptureui` (the floating thumbnail and the ⌘⇧5 toolbar are small and don't count).
/// Reads only window bounds and owners, which need no Screen Recording permission.
enum ScreenshotOverlay {
    @MainActor
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
