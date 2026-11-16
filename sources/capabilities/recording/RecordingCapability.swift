import AppKit
import FairyCore
import FairyKit

/// ⌘⇧6 records the display under the cursor to a .mov in the captures folder. While recording,
/// ⌥ + scroll zooms the video in and out, holding ⌥ moves the zoomed view with the cursor, and
/// the cursor is drawn larger. ⌘⇧7 and ⌘⇧8 turn the cursor into a pen or a highlighter that
/// draws on screen, in the video.
@MainActor
public final class RecordingCapability: Capability {
    public static let manifest = CapabilityManifest(
        id: "fairy.screen-recording",
        name: "Screen Recording",
        summary: "\(RecordingInput.shortcutLabel) to record. ⌥ + scroll zooms, hold ⌥ to move the view, \(RecordingInput.penLabel) / \(RecordingInput.highlighterLabel) to draw.",
        permissions: [.screenRecording, .accessibility],
        shortcuts: [RecordingInput.shortcutLabel, RecordingInput.penLabel, RecordingInput.highlighterLabel]
    )

    private enum State { case idle, starting, recording, stopping }

    private weak var host: FairyHost?
    private var input: RecordingInput?
    private var recorder: ScreenRecorder?
    private var frame: RecordingFrame?
    private var ink: InkOverlay?
    private var state: State = .idle
    private var id: String { Self.manifest.id }

    public init() {}

    public func activate(host: FairyHost) {
        self.host = host
        CursorScale.restoreIfLeftEnlarged()
        let input = RecordingInput()
        input.onToggle = { [weak self] in self?.toggle() }
        input.onZoom = { [weak self] amount in self?.recorder?.zoom(by: amount) }
        input.isRecording = { [weak self] in self?.state == .recording }
        input.onInkKey = { [weak self] key in self?.ink?.press(key) ?? false }
        input.onOptionChanged = { [weak self] down in
            guard let recorder = self?.recorder else { return }
            recorder.setFollowing(down)
            FairyLog.write("⌥ \(down ? "down" : "up") — recorded area \(recorder.currentArea.integral)")
        }
        if !input.start() {
            FairyLog.write("recording shortcut unavailable — grant Accessibility and relaunch")
        }
        self.input = input
    }

    public func deactivate() {
        // Switched off or quitting mid-recording: finish the file rather than lose it.
        if state != .idle { finish(waitForFile: true) }
        CursorScale.restore()
        input?.stop()
        input = nil
        host = nil
    }

    public func menuItems() -> [NSMenuItem] {
        let title: String
        switch state {
        case .idle: title = "Record Screen (\(RecordingInput.shortcutLabel))"
        case .starting: title = "Starting Recording…"
        case .recording: title = "Stop Recording (\(RecordingInput.shortcutLabel))"
        case .stopping: title = "Saving Recording…"
        }
        var items: [NSMenuItem] = [ActionMenuItem(title, enabled: state == .idle || state == .recording) { [weak self] in self?.toggle() }]
        if state == .recording, let ink = ink {
            for (tool, label) in [(InkTool.pen, "Pen (\(RecordingInput.penLabel))"), (.highlighter, "Highlighter (\(RecordingInput.highlighterLabel))")] {
                let item = ActionMenuItem(label) { [weak ink] in _ = ink?.press(tool == .pen ? .pen : .highlighter) }
                item.state = ink.tool == tool ? .on : .off
                items.append(item)
            }
        }
        return items
    }

    // MARK: - Recording

    private func toggle() {
        switch state {
        case .idle: begin()
        case .recording: finish(waitForFile: false)
        case .starting, .stopping: break
        }
    }

    private func begin() {
        guard let host = host else { return }
        guard Permissions.screenRecording else {
            Permissions.openScreenRecordingSettings()
            return
        }
        // Record the display the cursor is on.
        let mouse = CGEvent(source: nil)?.location ?? .zero
        var displayID: CGDirectDisplayID = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(mouse, 1, &displayID, &count)

        let folder = host.capturesFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = Folders.captureURL("Screen Recording", ext: "mov", in: folder)

        state = .starting
        // While recording, ⌥ is for zooming, not for the other capabilities' gestures.
        host.setExclusive(true, owner: id)
        let frame = RecordingFrame(displayID: displayID)
        let recorder = ScreenRecorder()
        recorder.onStoppedUnexpectedly = { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    FairyLog.write("recording stopped by the system: \(error)")
                    self?.finish(waitForFile: false)
                }
            }
        }
        self.recorder = recorder
        self.frame = frame
        frame.show(area: { [weak recorder] in recorder?.currentArea ?? .zero })
        let windowID = frame.windowID
        FairyLog.write("recording display \(displayID) → \(url.lastPathComponent)")

        Task { @MainActor in
            do {
                try await recorder.start(displayID: displayID, excludingWindowIDs: [windowID], to: url)
                guard self.state == .starting else { return }
                self.state = .recording
                CursorScale.enlarge()
                self.showInk(displayID: displayID)
            } catch {
                FairyLog.write("recording failed to start: \(error)")
                self.frame?.close()
                self.frame = nil
                self.recorder = nil
                self.state = .idle
                self.host?.setExclusive(false, owner: self.id)
            }
        }
    }

    // MARK: - Pen

    private func showInk(displayID: CGDirectDisplayID) {
        let ink = InkOverlay(displayID: displayID)
        ink.onToolChanged = { [weak self] tool in
            guard let self = self else { return }
            self.frame?.setTool(tool)
            // While drawing, the fairy steps aside: it shouldn't follow the pen around the
            // video, and scribbling isn't a shake.
            self.host?.setCaptureUIVisible(tool != nil, owner: self.inkOwner)
        }
        ink.show()
        self.ink = ink
    }

    private func closeInk() {
        ink?.close()
        ink = nil
        frame?.setTool(nil)
        host?.setCaptureUIVisible(false, owner: inkOwner)
    }

    private var inkOwner: String { id + ".ink" }

    /// `waitForFile`: the app is quitting (or the capability is being switched off), so block
    /// briefly until the file is finalised and don't open Finder.
    private func finish(waitForFile: Bool) {
        let host = self.host
        guard let recorder = recorder else {
            state = .idle
            host?.setExclusive(false, owner: id)
            return
        }
        state = .stopping
        closeInk()
        CursorScale.restore()
        frame?.close()
        frame = nil
        let id = self.id
        let done = DispatchSemaphore(value: 0)
        recorder.stop { [weak self] url in
            MainActor.assumeIsolated {
                self?.recorder = nil
                self?.state = .idle
                host?.setExclusive(false, owner: id)
                if let url = url {
                    FairyLog.write("recording saved: \(url.path)")
                    if !waitForFile { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            done.signal()
        }
        if waitForFile {
            // Give the file a moment to be finalised before the process goes away.
            let deadline = Date().addingTimeInterval(3)
            while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
    }
}
