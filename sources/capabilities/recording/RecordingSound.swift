import AppKit
import AVFoundation

/// What a recording listens to. Out of the box, nothing: a video that quietly kept a voice or a
/// call would be a bad surprise. The choice is made in the sound panel (⌘⇧9 while recording) and
/// remembered for the next recording.
struct RecordingSound: Equatable, Sendable {
    /// Whatever the Mac is playing.
    var computer = false
    /// Your voice.
    var microphone = false
    /// Which microphone, by its unique ID. Nil: the one macOS is set to use.
    var microphoneID: String?

    var isSilent: Bool { !computer && !microphone }

    private static let computerKey = "recording.sound.computer"
    private static let microphoneKey = "recording.sound.microphone"
    private static let microphoneIDKey = "recording.sound.microphoneID"

    /// The last choice, minus anything that can't be honoured any more: a microphone the app is
    /// no longer allowed to use, or one that has been unplugged.
    static func saved() -> RecordingSound {
        let defaults = UserDefaults.standard
        var sound = RecordingSound(computer: defaults.bool(forKey: computerKey),
                                   microphone: defaults.bool(forKey: microphoneKey),
                                   microphoneID: defaults.string(forKey: microphoneIDKey))
        if sound.microphone, Microphones.access != .authorized { sound.microphone = false }
        if let id = sound.microphoneID, !Microphones.all().contains(where: { $0.id == id }) { sound.microphoneID = nil }
        return sound
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(computer, forKey: Self.computerKey)
        defaults.set(microphone, forKey: Self.microphoneKey)
        defaults.set(microphoneID, forKey: Self.microphoneIDKey)
    }
}

/// One microphone you can pick.
struct Microphone: Identifiable, Equatable {
    let id: String
    let name: String
}

enum Microphones {
    static var access: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Every microphone plugged in right now, built-in first.
    static func all() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The name of the one macOS uses when none is picked.
    static var defaultName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    /// macOS's own "would like to access the microphone" dialog (only ever shown once).
    static func ask(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in done(granted) }
        }
    }

    @MainActor
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
