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
        if hit.isEditableText, hit.subrole != (kAXSecureTextFieldSubrole as String) {
            info.editable = element
        } else if searchNearby, let found = EditableResolver.editableTarget(at: point, hit: node) {
            info.editable = found.element
        }
        return info
    }
}

func NSRunningApplicationBundleID(_ pid: pid_t) -> String? {
    NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
}
