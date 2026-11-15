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

    /// Prompt for whichever of `needed` is missing. Accessibility shows the system dialog; Screen
    /// Recording is requested through the CG API (it adds the app to the list and prompts once).
    public static func requestMissing(_ needed: Set<Permission>) {
        if needed.contains(.accessibility), !accessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if needed.contains(.screenRecording), !screenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
    }

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
