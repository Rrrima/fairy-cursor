import CoreGraphics
import FairyCore
import Foundation

/// Synthetic keystrokes for the paste.
enum Keys {
    static let rightArrow: CGKeyCode = 124
    static let v: CGKeyCode = 9

    /// Device-dependent "left ⌘" bit (NX_DEVICELCMDKEYMASK). Some apps look at it, not just the
    /// device-independent command flag.
    private static let leftCommandDeviceBit: UInt64 = 0x0000_0008

    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keep the user's own mouse working while our keystrokes are in flight.
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                           state: .eventSuppressionStateSuppressionInterval)
        return source
    }()

    /// Press a key.
    ///  - `.session`: into the session event stream, so the frontmost app gets it exactly like
    ///    real typing (key equivalents, global modifier state). Used whenever the target is
    ///    frontmost.
    ///  - `.process(pid)`: straight to that process; a fallback when the target could not be
    ///    brought to the front. Many native apps ignore a ⌘V delivered this way.
    static func press(_ key: CGKeyCode, command: Bool = false, route: PastePolicy.KeyRoute) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        let flags: CGEventFlags = command ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | leftCommandDeviceBit) : []
        down.flags = flags
        up.flags = flags
        switch route {
        case .session:
            down.post(tap: .cgSessionEventTap)
            usleep(15_000)
            up.post(tap: .cgSessionEventTap)
        case .process(let pid):
            down.postToPid(pid)
            usleep(15_000)
            up.postToPid(pid)
        }
    }
}
