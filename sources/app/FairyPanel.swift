import AppKit
import SwiftUI

/// Transparent, click-through, always-on-top panel that hosts the SwiftUI fairy.
final class FairyPanel: NSPanel {
    init(state: FairyState) {
        super.init(
            contentRect: NSRect(origin: .zero, size: FairyLayout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        // Keep the fairy out of screenshots and screen recordings (it would otherwise appear in
        // the very capture it is about to hold). FAIRY_CAPTURABLE=1 re-enables for debugging.
        sharingType = ProcessInfo.processInfo.environment["FAIRY_CAPTURABLE"] == "1" ? .readOnly : .none
        setAccessibilityElement(false)   // never be the AX element under the cursor

        let hosting = NSHostingView(rootView: FairyView(state: state))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
