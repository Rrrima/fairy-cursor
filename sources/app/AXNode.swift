import AppKit
import ApplicationServices
import CursorMonitorKit
import FairyCore
import Foundation

/// A live accessibility element seen through FairyCore's `AccessibilityNode`. Attributes are
/// read lazily and cached (every read is IPC to the target app, bounded by a 250 ms timeout).
/// Thread-safe to *create* anywhere; use one instance from one thread.
final class AXNode: AccessibilityNode {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, 0.25)
    }

    private lazy var attributeNames: [String] = {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }()

    lazy var role: String? = axStringAttribute(element, kAXRoleAttribute)
    lazy var subrole: String? = axStringAttribute(element, kAXSubroleAttribute)

    lazy var frame: CGRect? = {
        guard let origin = pointValue(kAXPositionAttribute), let size = sizeValue(kAXSizeAttribute) else { return nil }
        return CGRect(origin: origin, size: size)
    }()

    lazy var parent: AXNode? = {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref) == .success,
              let ref = ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return AXNode(ref as! AXUIElement)
    }()

    lazy var children: [AXNode] = {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let list = ref as? [AnyObject] else { return [] }
        return list.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? AXNode(item as! AXUIElement) : nil
        }
    }()

    var hasEditableAncestorAttribute: Bool { attributeNames.contains("AXEditableAncestor") }

    lazy var isSettableTextValue: Bool = {
        guard attributeNames.contains(kAXSelectedTextRangeAttribute as String) else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }()

    /// Chromium and WebKit expose the DOM classes of web elements.
    lazy var domClasses: [String] = {
        guard attributeNames.contains("AXDOMClassList") else { return [] }
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &ref) == .success else { return [] }
        return (ref as? [String]) ?? []
    }()

    /// The address of a web area.
    var url: String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &ref) == .success else { return nil }
        return (ref as? URL)?.absoluteString ?? (ref as? String)
    }

    /// The element and its ancestors, nearest first, up to (and including) the window.
    func chain(limit: Int = 12) -> [AXNode] {
        var nodes: [AXNode] = []
        var current: AXNode? = self
        while let node = current, nodes.count < limit {
            nodes.append(node)
            if node.role == "AXWindow" || node.role == "AXApplication" { break }
            current = node.parent
        }
        return nodes
    }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid > 0 ? pid : nil
    }

    /// Roles of the ancestors, nearest first (bounded).
    func ancestorRoles(limit: Int = 8) -> [String] {
        var roles: [String] = []
        var current = parent
        while let node = current, roles.count < limit {
            roles.append(node.role ?? "")
            current = node.parent
        }
        return roles
    }

    /// The focused element of an application.
    static func focused(in pid: pid_t) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref = ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return AXNode(ref as! AXUIElement)
    }

    private func pointValue(_ attribute: String) -> CGPoint? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref = ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func sizeValue(_ attribute: String) -> CGSize? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref = ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &size) ? size : nil
    }
}

/// What a point on screen offers the fairy, resolved off the main thread.
struct DropSpotInfo {
    var pid: pid_t?
    var bundleID: String?
    var finderDropSpot = false
    /// The text input to paste into (the hit element, its editable ancestor, or an editable
    /// element under its placeholder label).
    var editable: AXUIElement?
    /// A terminal inside a web view (VS Code, Cursor): it takes text only, like a terminal app.
    var webTerminal = false
    /// No text input, but a surface that takes a pasted image anywhere (a slide, a Figma board).
    var canvas = false
    var knownCanvasApp = false
    /// The canvas is a text document the page draws itself (Google Docs).
    var document = false

    /// What kind of thing a paste here goes into.
    var surface: PasteTarget.Surface {
        if webTerminal || PasteTarget.isTerminal(pid: pid) { return .terminal }
        return editable == nil && canvas ? (document ? .document : .canvas) : .field
    }

    /// Hit-test `point` (global CG) and classify it. Call off the main thread: it may walk a
    /// few dozen accessibility elements.
    static func resolve(at point: CGPoint, searchNearby: Bool = true) -> DropSpotInfo {
        var info = DropSpotInfo()
        let hit = axElementAtPoint(point)
        guard let element = hit.element else { return info }
        let node = AXNode(element)
        info.pid = node.pid
        info.bundleID = info.pid.flatMap { NSRunningApplicationBundleID($0) }
        if info.bundleID == FinderTarget.finderBundleID {
            info.finderDropSpot = FinderDropPolicy.isDropSpot(role: hit.role, ancestorRoles: node.ancestorRoles())
            return info
        }
        let chain = node.chain()
        let webArea = chain.first { $0.role == "AXWebArea" }
        if webArea != nil, isWebTerminal(chain) {
            info.webTerminal = true
            info.editable = element
            return info
        }
        if hit.isEditableText, hit.subrole != (kAXSecureTextFieldSubrole as String) {
            info.editable = element
        } else if searchNearby, let found = EditableResolver.editableTarget(at: point, hit: node) {
            info.editable = found.element
        }
        if info.editable == nil {
            (info.canvas, info.knownCanvasApp, info.document) = canvasFacts(chain: chain, bundleID: info.bundleID)
        }
        return info
    }

    /// Is the element (first in `chain`) part of a canvas, and is this a known canvas app?
    static func canvasFacts(chain: [AXNode], bundleID: String?) -> (canvas: Bool, known: Bool, document: Bool) {
        guard let node = chain.first else { return (false, false, false) }
        let webArea = chain.first { $0.role == "AXWebArea" }
        let url = webArea?.url
        let spot = CanvasPolicy.Spot(role: node.role, ancestorRoles: chain.dropFirst().map { $0.role ?? "" },
                                     frame: node.frame, webAreaFrame: webArea?.frame, url: url, bundleID: bundleID)
        return (CanvasPolicy.isCanvas(spot), CanvasPolicy.isKnownCanvasApp(bundleID: bundleID, url: url),
                CanvasPolicy.isPageDrawnDocument(url: url))
    }

    /// xterm.js (the terminal in VS Code, Cursor and most Electron apps) marks its elements
    /// with `xterm…` classes.
    static func isWebTerminal(_ chain: [AXNode]) -> Bool {
        for node in chain.prefix(8) {
            if node.role == "AXWebArea" { break }
            if node.domClasses.contains(where: { $0.hasPrefix("xterm") }) { return true }
        }
        return false
    }

    static func isWebTerminal(_ element: AXUIElement?) -> Bool {
        guard let element = element else { return false }
        return isWebTerminal(AXNode(element).chain(limit: 8))
    }
}

func NSRunningApplicationBundleID(_ pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}
