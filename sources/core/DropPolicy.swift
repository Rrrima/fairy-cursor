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
        /// A terminal that did not answer the accessibility lookup in time (busy printing): its
        /// window is one big text view, so paste rather than drop the gesture.
        public var silentTerminal: Bool

        public init(isHolding: Bool, hiddenForCapture: Bool = false, busy: Bool = false, clickCount: Int = 2,
                    targetIsOwnProcess: Bool = false, isFinder: Bool = false, finderDropSpot: Bool = false,
                    editableUnderCursor: Bool = false, silentTerminal: Bool = false) {
            self.isHolding = isHolding
            self.hiddenForCapture = hiddenForCapture
            self.busy = busy
            self.clickCount = clickCount
            self.targetIsOwnProcess = targetIsOwnProcess
            self.isFinder = isFinder
            self.finderDropSpot = finderDropSpot
            self.editableUnderCursor = editableUnderCursor
            self.silentTerminal = silentTerminal
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
        return c.editableUnderCursor || c.silentTerminal ? .paste : .checkFocusAfterMouseUp
    }

    /// After the mouse-up, no text input was found but the spot looks like a canvas (a slide, a
    /// Figma board): paste there unless typing is visibly going somewhere else, in which case
    /// the ⌘V would land in that field instead of on the canvas.
    public static func confirmCanvasDrop(point: CGPoint, canvasSpot: Bool, knownCanvasApp: Bool,
                                         focusedEditable: Bool, focusedFrame: CGRect?) -> Bool {
        guard canvasSpot else { return false }
        // Canvas apps keep an invisible text field focused to catch typing; trust them.
        if knownCanvasApp || !focusedEditable { return true }
        guard let frame = focusedFrame else { return true }
        return !CanvasPolicy.isVisibleField(frame)
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

/// Canvases: slides, whiteboards and design tools take a pasted image anywhere on their surface,
/// but have no text input to recognise. Pure: the caller reads the accessibility facts.
public enum CanvasPolicy {
    public struct Spot {
        public var role: String?
        /// Nearest first, up to the window.
        public var ancestorRoles: [String]
        public var frame: CGRect?
        /// The web page the element is in (nil for native views).
        public var webAreaFrame: CGRect?
        public var url: String?
        public var bundleID: String?

        public init(role: String?, ancestorRoles: [String] = [], frame: CGRect? = nil, webAreaFrame: CGRect? = nil,
                    url: String? = nil, bundleID: String? = nil) {
            self.role = role
            self.ancestorRoles = ancestorRoles
            self.frame = frame
            self.webAreaFrame = webAreaFrame
            self.url = url
            self.bundleID = bundleID
        }
    }

    /// Controls and lists: a double-click there means something else (open, rename, zoom).
    static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
        "AXRadioButton", "AXSlider", "AXScrollBar", "AXTabGroup", "AXToolbar", "AXDisclosureTriangle",
        "AXIncrementor", "AXColorWell", "AXCell", "AXRow", "AXColumn", "AXHeading", "AXStaticText", "AXWindow",
    ]
    static let controlAncestorRoles: Set<String> = [
        "AXToolbar", "AXMenuBar", "AXMenu", "AXTabGroup", "AXButton", "AXLink", "AXPopover", "AXSheet",
        "AXOutline", "AXTable", "AXList", "AXRow", "AXCell",
    ]
    /// What a canvas surface looks like in a known canvas app.
    static let surfaceRoles: Set<String> = ["AXLayoutArea", "AXScrollArea", "AXGroup", "AXImage", "AXUnknown", "AXCanvas", "AXWebArea", "AXSplitGroup"]

    static let canvasBundlePrefixes = [
        "com.figma.", "com.apple.iWork.Keynote", "com.apple.iWork.Pages", "com.apple.Keynote", "com.apple.Pages",
        "com.microsoft.Powerpoint", "com.apple.freeform", "com.electron.realtimeboard", "com.miro.",
        "com.canva.", "com.bohemiancoding.sketch", "com.adobe.illustrator", "com.adobe.Photoshop",
        "com.seriflabs.", "com.pixelmatorteam.", "com.lukilabs.lukiapp", "com.tldraw.", "com.pitch.",
        "com.omnigroup.OmniGraffle",
    ]
    static let canvasHosts = [
        "figma.com", "miro.com", "canva.com", "excalidraw.com", "tldraw.com", "whimsical.com", "lucid.app",
        "app.diagrams.net", "pitch.com", "jamboard.google.com", "framer.com", "penpot.app",
    ]
    /// Google's editors draw the page themselves and catch typing in a hidden field.
    static let canvasURLPrefixes = ["docs.google.com/presentation", "docs.google.com/drawings"]
    /// Text documents drawn the same way. They are found like a canvas but pasted into like a
    /// text field: the double-click selected a word, so the selection is collapsed first and
    /// the image lands after that word instead of replacing it.
    static let documentURLPrefixes = ["docs.google.com/document"]

    public static func isPageDrawnDocument(url: String?) -> Bool {
        guard let url = url, let key = hostAndPath(url) else { return false }
        return documentURLPrefixes.contains { key.hasPrefix($0) }
    }

    public static func isKnownCanvasApp(bundleID: String?, url: String?) -> Bool {
        if let bundle = bundleID, canvasBundlePrefixes.contains(where: { bundle.hasPrefix($0) }) { return true }
        guard let url = url, let key = hostAndPath(url) else { return false }
        let host = key.split(separator: "/").first.map(String.init) ?? key
        if canvasHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        return canvasURLPrefixes.contains { key.hasPrefix($0) } || documentURLPrefixes.contains { key.hasPrefix($0) }
    }

    /// "https://www.figma.com/design/x?y" → "figma.com/design/x".
    static func hostAndPath(_ url: String) -> String? {
        guard let scheme = url.range(of: "://") else { return nil }
        var rest = String(url[scheme.upperBound...])
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = String(rest[..<cut]) }
        if rest.hasPrefix("www.") { rest.removeFirst(4) }
        return rest.isEmpty ? nil : rest.lowercased()
    }

    public static func isCanvas(_ s: Spot) -> Bool {
        guard let role = s.role, !controlRoles.contains(role) else { return false }
        if s.ancestorRoles.contains(where: { controlAncestorRoles.contains($0) }) { return false }
        if isKnownCanvasApp(bundleID: s.bundleID, url: s.url) { return surfaceRoles.contains(role) }
        // Anywhere else: a web page's <canvas> (browsers call it an image) that fills most of
        // the page, or a native layout area (how drawing surfaces describe themselves).
        if role == "AXLayoutArea" { return true }
        if role == "AXImage" || role == "AXCanvas", let frame = s.frame, let page = s.webAreaFrame {
            let visible = frame.intersection(page)
            guard !visible.isNull, page.width > 0, page.height > 0 else { return false }
            return visible.width * visible.height >= 0.5 * page.width * page.height
        }
        return false
    }

    /// A focused field the user can see (as opposed to the tiny or off-screen one a canvas app
    /// uses to catch typing).
    public static func isVisibleField(_ frame: CGRect) -> Bool {
        frame.width >= 24 && frame.height >= 10 && frame.maxX > 0 && frame.maxY > 0
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
