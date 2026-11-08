import CoreGraphics
import Foundation

/// What a double-click while carrying screenshots should do. Pure: the caller gathers the facts
/// (from the cursor event and accessibility) and acts on the answer.
public enum DropPolicy {
    public struct DoubleClick {
        public var isHolding: Bool
        /// The system screenshot UI is up (the fairy is hidden).
        public var hiddenForCapture: Bool
        /// A delivery is already in progress.
        public var busy: Bool
        public var clickCount: Int
        /// The element under the cursor belongs to Fairy Cursor itself (a note): notes handle
        /// their own double-click.
        public var targetIsOwnProcess: Bool
        public var isFinder: Bool
        public var finderDropSpot: Bool
        /// The element under the cursor (or its editable ancestor) takes typed text.
        public var editableUnderCursor: Bool

        public init(isHolding: Bool, hiddenForCapture: Bool = false, busy: Bool = false, clickCount: Int = 2,
                    targetIsOwnProcess: Bool = false, isFinder: Bool = false, finderDropSpot: Bool = false,
                    editableUnderCursor: Bool = false) {
            self.isHolding = isHolding
            self.hiddenForCapture = hiddenForCapture
            self.busy = busy
            self.clickCount = clickCount
            self.targetIsOwnProcess = targetIsOwnProcess
            self.isFinder = isFinder
            self.finderDropSpot = finderDropSpot
            self.editableUnderCursor = editableUnderCursor
        }
    }

    public enum Action: Equatable {
        case ignore
        case saveToFinder
        case paste
        /// Not recognisably a text input yet: after the mouse-up, ask the app what got focus
        /// (custom composers, placeholder overlays, web views that expose inputs late).
        case checkFocusAfterMouseUp
    }

    public static func decide(_ c: DoubleClick) -> Action {
        guard c.isHolding, !c.hiddenForCapture, !c.busy, c.clickCount == 2, !c.targetIsOwnProcess else { return .ignore }
        if c.isFinder { return c.finderDropSpot ? .saveToFinder : .ignore }
        return c.editableUnderCursor ? .paste : .checkFocusAfterMouseUp
    }

    /// After the mouse-up: is there a text input to paste into at `point`?
    /// - hitEditable: the element now under the cursor is editable (web inputs that appeared late).
    /// - focused: the app's focused element, if editable, and its frame (global CG points).
    /// - nearbyEditable: an editable element found next to the hit element whose frame contains
    ///   the point (a composer hidden under its placeholder label).
    public static func confirmAfterMouseUp(point: CGPoint, hitEditable: Bool,
                                           focusedEditable: Bool, focusedFrame: CGRect?,
                                           nearbyEditable: Bool) -> Bool {
        if hitEditable || nearbyEditable { return true }
        // Focus alone is not enough: a double-click on a toolbar must not paste into a text
        // field elsewhere in the window. The click has to be inside the focused field.
        if focusedEditable, let frame = focusedFrame, frame.insetBy(dx: -6, dy: -6).contains(point) { return true }
        return false
    }
}

/// Finder: which double-clicks mean "save it here".
public enum FinderDropPolicy {
    /// Roles that are the empty background of a folder view (or the desktop) rather than an item
    /// (which the double-click would open). `AXWindow` is deliberately absent: a double-click on
    /// a window's title bar zooms the window and must not dump the pile into the folder.
    public static let containerRoles: Set<String> = [
        "AXScrollArea", "AXGroup", "AXList", "AXOutline", "AXTable", "AXBrowser",
        "AXSplitGroup", "AXLayoutArea", "AXGrid",
    ]
    /// Anywhere inside these is window chrome, not a folder view.
    public static let chromeAncestorRoles: Set<String> = ["AXToolbar", "AXTabGroupBar", "AXMenuBar", "AXMenu", "AXSheet", "AXPopover"]

    public static func isDropSpot(role: String?, ancestorRoles: [String] = []) -> Bool {
        guard let role = role, containerRoles.contains(role) else { return false }
        return !ancestorRoles.contains { chromeAncestorRoles.contains($0) }
    }
}
