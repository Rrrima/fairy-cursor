import AppKit
import SwiftUI

// FairyKit is what a capability is written against. The fairy itself (the cursor companion that
// carries screenshots, shakes them off, and drops them into apps and folders) is the host; a
// capability is one thing it can do on top: take screenshots, write notes, record the screen.
//
// A capability never talks to another capability. Anything two of them share (what the fairy is
// carrying, whether the screen is taken, where captures are saved) goes through `FairyHost`.

/// Who a capability is and what it needs. Shown in Settings → Capabilities.
public struct CapabilityManifest: Sendable {
    /// Reverse-DNS style and stable forever: it keys the on/off switch and the capability's
    /// settings ("fairy.notes", "com.someone.ocr").
    public let id: String
    public let name: String
    /// One line for Settings: what it does and how you start it.
    public let summary: String
    public let version: String
    public let permissions: Set<Permission>
    /// The global shortcuts it takes, for display ("⌘⇧6").
    public let shortcuts: [String]

    public init(id: String, name: String, summary: String, version: String = "1.0",
                permissions: Set<Permission> = [], shortcuts: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.version = version
        self.permissions = permissions
        self.shortcuts = shortcuts
    }
}

/// One thing the fairy can do. The host creates it once, then activates and deactivates it as
/// the user switches it on and off in Settings (and deactivates it when the app quits).
@MainActor
public protocol Capability: AnyObject {
    static var manifest: CapabilityManifest { get }
    init()

    /// Start: install monitors, taps, windows. `host` stays valid until `deactivate`.
    func activate(host: FairyHost)
    /// Stop and clean up everything `activate` started (the user switched it off, or the app is
    /// quitting). Must leave the system as it found it: shortcuts released, system settings put back.
    func deactivate()

    /// Items for the menu bar menu, built each time it opens. Default: none.
    func menuItems() -> [NSMenuItem]
    /// Rows for this capability's section in Settings (use `ToggleRow`, `FolderRow`). Default: none.
    func settingsView() -> AnyView?
}

public extension Capability {
    func menuItems() -> [NSMenuItem] { [] }
    func settingsView() -> AnyView? { nil }
}

/// A place on screen that takes the fairy's pile itself (a note): the fairy leaves double-clicks
/// there to it and shows `hint` while hovering. Points are in AppKit screen coordinates.
public struct DropZone {
    public let contains: @MainActor (CGPoint) -> Bool
    public let hint: String

    public init(hint: String, contains: @escaping @MainActor (CGPoint) -> Bool) {
        self.hint = hint
        self.contains = contains
    }
}

/// What the fairy offers its capabilities. Everything a capability sets with an `owner` is undone
/// for it when it's deactivated.
@MainActor
public protocol FairyHost: AnyObject {
    // MARK: The pile

    /// Hand the fairy a screenshot to carry. `kept`: it's already saved, so shaking only lets go.
    func carry(_ image: CGImage, scale: CGFloat, capturedAt: Date, kept: Bool)
    /// Remember a screenshot only for "Restore Last Screenshot", without putting it on the pile.
    func keepForRestore(_ image: CGImage, scale: CGFloat, capturedAt: Date)
    /// What the fairy is carrying, top card first (empty when its hands are free).
    var carried: [HeldScreenshot] { get }
    /// These carried screenshots were used (pasted, saved, put in a note): the fairy lets go of them.
    func delivered(_ ids: [UUID], hint: String)

    // MARK: The screen

    /// The system screenshot UI is up: the fairy steps out of the way and cursor movement is not a shake.
    func setCaptureUIVisible(_ visible: Bool, owner: String)
    /// This capability has the screen to itself for a while (a recording): other capabilities'
    /// gestures (holding ⌥ for a note) stand down until it's released.
    func setExclusive(_ on: Bool, owner: String)
    /// True while the capture UI is up or any capability holds the screen.
    var isScreenBusy: Bool { get }
    /// Where `owner`'s windows take the pile themselves; nil removes it.
    func setDropZone(_ zone: DropZone?, owner: String)

    // MARK: Files

    /// Where captures the user keeps are saved (screenshots, recordings). Chosen in Settings.
    var capturesFolder: URL { get }
}

/// A menu item that runs a closure, so a capability needn't be an NSObject with selectors.
public final class ActionMenuItem: NSMenuItem {
    private let run: () -> Void

    public init(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

/// Debug lines go to the console when the app runs with FAIRY_DEBUG=1.
public enum FairyLog {
    public static let enabled = ProcessInfo.processInfo.environment["FAIRY_DEBUG"] == "1"

    public static func write(_ message: String) {
        if enabled { NSLog("[FairyCursor] \(message)") }
    }
}
