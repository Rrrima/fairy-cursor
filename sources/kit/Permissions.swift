import AppKit
import ApplicationServices

/// A macOS privacy permission a capability needs. The app asks only for what its enabled
/// capabilities (and the fairy itself) list.
public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen recording"
        }
    }

    public var isGranted: Bool {
        switch self {
        case .accessibility: return Permissions.accessibility
        case .screenRecording: return Permissions.screenRecording
        }
    }

    public func openSettings() {
        switch self {
        case .accessibility: Permissions.openAccessibilitySettings()
        case .screenRecording: Permissions.openScreenRecordingSettings()
        }
    }
}

public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    @MainActor private static var asked: Set<Permission> = []

    /// What an "Allow…" button does. The first time, macOS's own dialog: that is what puts the
    /// app in the list in System Settings, with a button that goes there. After that the dialog
    /// won't come back, so go straight to the list.
    @MainActor
    public static func allow(_ permission: Permission) {
        guard asked.insert(permission).inserted else { return permission.openSettings() }
        switch permission {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            // Says false both when it has just asked and when it was turned down before.
            if !CGRequestScreenCaptureAccess() && wasAskedBefore(permission) { permission.openSettings() }
        }
        UserDefaults.standard.set(true, forKey: askedKey(permission))
    }

    private static func askedKey(_ permission: Permission) -> String { "permissions.asked.\(permission.rawValue)" }
    private static func wasAskedBefore(_ permission: Permission) -> Bool { UserDefaults.standard.bool(forKey: askedKey(permission)) }

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
