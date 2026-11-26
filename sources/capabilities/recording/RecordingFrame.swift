import AppKit
import FairyCore
import FairyKit
import SwiftUI

/// What you see while recording, and never in the video: a soft blue outline around the area
/// being recorded (it shrinks and slides as you zoom) and a small glass pill at the top of the
/// screen with the elapsed time and the zoom hint. Click-through; kept out of the capture by
/// window ID (see `ScreenRecorder.start`).
///
/// The sound panel lives here too: a small glass card that drops from under the pill while the
/// recording is paused. Only then does this window take clicks, and a click anywhere outside
/// the card carries on recording.
@MainActor
final class RecordingFrame {
    private let panel: NSPanel
    private let outline = CAShapeLayer()
    private let display: CGRect          // global points, top-left origin
    private let model = PillModel()
    private let soundModel = SoundModel()
    private var timer: Timer?
    private let started = Date()
    /// Time spent paused isn't in the video, so it isn't in the pill's clock either.
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var onSoundDone: (RecordingSound) -> Void = { _ in }

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
        // Like the fairy: out of screenshots unless FAIRY_CAPTURABLE=1 (to look at it while testing).
        panel.sharingType = ProcessInfo.processInfo.environment["FAIRY_CAPTURABLE"] == "1" ? .readOnly : .none
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
        pill.frame = NSRect(x: 0, y: 0, width: 640, height: 44)
        let menuBar = frame.maxY - (screen?.visibleFrame.maxY ?? frame.maxY)
        pill.frame.origin = NSPoint(x: (frame.width - pill.frame.width) / 2, y: frame.height - menuBar - pill.frame.height - 8)
        root.addSubview(pill)

        // The sound panel's layer covers the whole screen so a click outside the card can be
        // caught; the card itself hangs just under the pill.
        let sound = FirstClickHostingView(rootView: SoundPanel(
            model: soundModel, top: frame.height - pill.frame.minY + 6,
            toggleComputer: { [weak self] in self?.soundKey(.computer) },
            toggleMicrophone: { [weak self] in self?.soundKey(.microphone) },
            choose: { [weak self] id in self?.soundModel.sound.microphoneID = id },
            done: { [weak self] in self?.soundKey(.done) }))
        sound.frame = root.bounds
        sound.autoresizingMask = [.width, .height]
        root.addSubview(sound, positioned: .below, relativeTo: pill)
        panel.contentView = root
    }

    func show(area: @escaping () -> CGRect) {
        update(area())
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.update(area())
                let now = self.pausedAt ?? Date()
                self.model.elapsed = Int(now.timeIntervalSince(self.started) - self.pausedTotal)
            }
        }
    }

    /// The pill says what the cursor draws with, and the keys that go with it.
    func setTool(_ tool: InkTool?) {
        model.tool = tool
    }

    /// What the recording is listening to, shown on the pill.
    func setSound(_ sound: RecordingSound) {
        model.sound = sound
    }

    // MARK: - Sound panel

    var isChoosingSound: Bool { soundModel.open }

    /// Pause the clock and drop the panel. `done` gets the choice when it's put away.
    func openSound(current: RecordingSound, done: @escaping (RecordingSound) -> Void) {
        onSoundDone = done
        pausedAt = Date()
        model.paused = true
        soundModel.sound = current
        soundModel.microphones = Microphones.all()
        soundModel.defaultMicrophone = Microphones.defaultName
        soundModel.denied = false
        soundModel.open = true
        panel.ignoresMouseEvents = false
    }

    /// The recording is running again.
    func resumed() {
        if let pausedAt = pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        model.paused = false
    }

    func soundKey(_ key: SoundKey) {
        guard soundModel.open else { return }
        switch key {
        case .computer:
            soundModel.sound.computer.toggle()
        case .microphone:
            toggleMicrophone()
        case .previous, .next:
            guard soundModel.sound.microphone else { return }
            // "The one macOS uses" first, then each microphone.
            let ids: [String?] = [nil] + soundModel.microphones.map { Optional($0.id) }
            let at = ids.firstIndex(of: soundModel.sound.microphoneID) ?? 0
            soundModel.sound.microphoneID = ids[max(0, min(ids.count - 1, at + (key == .next ? 1 : -1)))]
        case .done:
            soundModel.open = false
            panel.ignoresMouseEvents = true
            onSoundDone(soundModel.sound)
        }
    }

    /// The microphone needs macOS's say-so, asked for the first time it's switched on.
    private func toggleMicrophone() {
        if soundModel.sound.microphone {
            soundModel.sound.microphone = false
            return
        }
        switch Microphones.access {
        case .authorized:
            soundModel.sound.microphone = true
        case .notDetermined:
            // macOS's dialog must be clickable even where it sits under this window.
            panel.ignoresMouseEvents = true
            Microphones.ask { [weak self] granted in
                guard let self = self, self.soundModel.open else { return }
                self.panel.ignoresMouseEvents = false
                self.soundModel.sound.microphone = granted
                self.soundModel.denied = !granted
                self.soundModel.microphones = Microphones.all()
                self.soundModel.defaultMicrophone = Microphones.defaultName
            }
        default:
            if soundModel.denied { Microphones.openSettings() }
            soundModel.denied = true
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
    @Published var tool: InkTool?
    @Published var paused = false
    @Published var sound = RecordingSound()
}

@MainActor
private final class SoundModel: ObservableObject {
    @Published var open = false
    @Published var sound = RecordingSound()
    @Published var microphones: [Microphone] = []
    @Published var defaultMicrophone: String?
    /// macOS said no to the microphone: say so, and where to change it.
    @Published var denied = false
}

/// A click on the panel should land the first time, though the fairy is never the front app.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// "● 0:42 · ⌥ scroll to zoom · ⌘⇧7 pen · ⌘⇧6 to stop" on one glass pill; the dot breathes.
/// With a pen in hand it names the tool and the keys for it instead.
private struct RecordingPill: View {
    @ObservedObject var model: PillModel
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hue: 212 / 360, saturation: 0.62, brightness: 0.86))
                .frame(width: 7, height: 7)
                // Paused, it holds still and dim: the breathing is the recording being live.
                .opacity(model.paused ? 0.3 : (breathe ? 1 : 0.45))
                .animation(model.paused ? .easeOut(duration: 0.2) : .easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: breathe)
                .animation(.easeOut(duration: 0.2), value: model.paused)
            Text(String(format: "%d:%02d", model.elapsed / 60, model.elapsed % 60))
                .font(Theme.font(12.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            // What the video is hearing, said plainly: nobody should be recorded by surprise.
            if model.sound.computer {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if model.sound.microphone {
                Image(systemName: "mic.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.text)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if model.paused {
                Text("paused")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("choose what the video hears · return to keep recording")
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.muted)
            } else if let tool = model.tool {
                Text(tool == .pen ? "pen" : "highlighter")
                    .font(Theme.font(12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(hints(for: tool))
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.muted)
            } else {
                Text("⌥ scroll to zoom · \(RecordingInput.penLabel) pen · \(RecordingInput.highlighterLabel) highlighter · \(RecordingInput.soundLabel) sound · \(RecordingInput.shortcutLabel) to stop")
                    .font(Theme.font(11.5))
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular.tint(.white.opacity(0.3)), in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { breathe = true }
        .animation(.easeOut(duration: 0.2), value: model.tool)
        .animation(.easeOut(duration: 0.2), value: model.paused)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.sound)
    }

    private func hints(for tool: InkTool) -> String {
        let other = tool == .pen ? "\(RecordingInput.highlighterLabel) highlighter" : "\(RecordingInput.penLabel) pen"
        return "\(other) · ⌘Z undo · ⌫ clear · esc done"
    }
}

// MARK: - Sound panel

/// What the video hears: the computer, the microphone, both or neither. A glass card under the
/// pill, in the pill's own material; it grows out of the pill and goes back into it.
private struct SoundPanel: View {
    @ObservedObject var model: SoundModel
    /// How far below the top of the screen the card hangs.
    let top: CGFloat
    let toggleComputer: () -> Void
    let toggleMicrophone: () -> Void
    let choose: (String?) -> Void
    let done: () -> Void

    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        ZStack(alignment: .top) {
            // Anywhere that isn't the card: carry on recording.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: done)
                .allowsHitTesting(model.open)
            card
                .padding(.top, top)
                .opacity(model.open ? 1 : 0)
                .scaleEffect(model.open ? 1 : 0.92, anchor: .top)
                .offset(y: model.open ? 0 : -10)
                .allowsHitTesting(model.open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.open)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("what the video hears")
                .font(Theme.font(11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 5)

            SoundRow(symbol: "speaker.wave.2", title: "Computer sound", key: "1", isOn: model.sound.computer, action: toggleComputer)
            SoundRow(symbol: "mic", title: "Microphone", key: "2", isOn: model.sound.microphone, action: toggleMicrophone)

            if model.sound.microphone {
                // Which one: rows on the same glass, set in under the word they belong to.
                VStack(alignment: .leading, spacing: 0) {
                    MicrophoneRow(name: model.defaultMicrophone.map { "the Mac's choice · \($0)" } ?? "the Mac's choice",
                                  chosen: model.sound.microphoneID == nil) { choose(nil) }
                    ForEach(model.microphones) { microphone in
                        MicrophoneRow(name: microphone.name, chosen: model.sound.microphoneID == microphone.id) { choose(microphone.id) }
                    }
                }
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
            if model.denied {
                Button(action: toggleMicrophone) {
                    Text("macOS isn't letting Fairy Cursor use the microphone. open settings →")
                        .font(Theme.font(11.5))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 43)
                        .padding(.trailing, 16)
                        .padding(.bottom, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                Spacer()
                KeyTile("return")
                Button(action: done) {
                    Text("Keep recording")
                        .font(Theme.font(12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        // The one dark thing on the card: the way on.
                        .background(Capsule().fill(Theme.text))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(width: 300)
        .glassEffect(.regular.tint(.white.opacity(0.3)), in: shape)
        .glassShadow()
        .animation(.spring(response: 0.36, dampingFraction: 0.8), value: model.sound)
        .animation(.easeOut(duration: 0.2), value: model.denied)
    }
}

/// One thing the video can hear: its picture, its name, its key, and a switch.
private struct SoundRow: View {
    let symbol: String
    let title: String
    let key: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isOn ? Theme.text : Theme.muted)
                    .frame(width: 17)
                Text(title)
                    .font(Theme.font(13.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                KeyTile(key)
                SoundSwitch(isOn: isOn)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hovering ? 0.45 : 0)))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A microphone to pick. The chosen one is marked with a dot in the recording blue: it's live.
private struct MicrophoneRow: View {
    let name: String
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hue: 212 / 360, saturation: 0.62, brightness: 0.86))
                    .frame(width: 5, height: 5)
                    .scaleEffect(chosen ? 1 : 0.01)
                    .opacity(chosen ? 1 : 0)
                    .frame(width: 17)
                Text(name)
                    .font(Theme.font(12.5, weight: chosen ? .medium : .regular))
                    .foregroundStyle(chosen ? Theme.text : Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 26)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovering ? 0.45 : 0)))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: chosen)
    }
}

/// A small switch: ink when on (blue is kept for what's live), the knob slides with a little spring.
private struct SoundSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Theme.text : Theme.slate.opacity(0.14))
            .frame(width: 30, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: Theme.slate.opacity(0.22), radius: 1.5, y: 0.5)
                    .padding(2)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
    }
}

/// A key, on a faint tile of the same glass.
private struct KeyTile: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(Theme.font(10.5, weight: .medium))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 5.5)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5.5, style: .continuous).fill(Theme.slate.opacity(0.07)))
            .fixedSize()
    }
}
