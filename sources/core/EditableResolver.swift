import CoreGraphics
import Foundation

/// The bits of an accessibility element the editable-text heuristics need. The app conforms
/// `AXUIElement` to it; tests use an in-memory tree.
public protocol AccessibilityNode {
    var role: String? { get }
    var subrole: String? { get }
    /// Global CG points (top-left origin), nil when the element has no geometry.
    var frame: CGRect? { get }
    var parent: Self? { get }
    var children: [Self] { get }
    /// Chromium marks every node inside an editable region with `AXEditableAncestor`.
    var hasEditableAncestorAttribute: Bool { get }
    /// `AXValue` is settable and the element has a text selection (`AXSelectedTextRange`):
    /// how custom text views (SwiftUI, Catalyst, canvas editors) look when their role is a
    /// generic group.
    var isSettableTextValue: Bool { get }
}

public enum EditableResolver {
    public static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let boundaryRoles: Set<String> = ["AXWindow", "AXApplication", "AXWebArea", "AXSheet"]
    /// Roles that can hold a settable value without being text.
    static let nonTextValueRoles: Set<String> = [
        "AXSlider", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXIncrementor", "AXColorWell",
        "AXDisclosureTriangle", "AXScrollBar", "AXValueIndicator", "AXStepper", "AXSwitch",
    ]

    /// Does this element itself take typed text?
    public static func isTextInput<N: AccessibilityNode>(_ node: N) -> Bool {
        if let role = node.role, editableRoles.contains(role) {
            // Secure fields take typing but never images; a paste would only be refused.
            return node.subrole != "AXSecureTextField"
        }
        if node.hasEditableAncestorAttribute { return true }
        if node.isSettableTextValue, !nonTextValueRoles.contains(node.role ?? "") { return true }
        return false
    }

    /// The element or one of its ancestors (up to the window / web area) takes typed text.
    public static func editableSelfOrAncestor<N: AccessibilityNode>(_ node: N, maxDepth: Int = 12) -> N? {
        var current: N? = node
        var depth = 0
        while let n = current, depth <= maxDepth {
            if isTextInput(n) { return n }
            if let role = n.role, boundaryRoles.contains(role) { return nil }
            current = n.parent
            depth += 1
        }
        return nil
    }

    /// An editable element at `point` near the hit element: the hit element's own editable
    /// ancestor, or an editable sibling/cousin whose frame contains the point. The second case is
    /// the empty chat composer, whose placeholder label ("Ask anything") sits on top of the
    /// text view, so hit-testing returns the label instead of the input.
    public static func editableTarget<N: AccessibilityNode>(at point: CGPoint, hit: N,
                                                            ancestorLevels: Int = 3,
                                                            searchDepth: Int = 3,
                                                            nodeBudget: Int = 80) -> N? {
        if let direct = editableSelfOrAncestor(hit) { return direct }
        var budget = nodeBudget
        var ancestor: N? = hit.parent
        for _ in 0..<ancestorLevels {
            guard let a = ancestor else { break }
            if let role = a.role, boundaryRoles.contains(role) { break }
            if let found = searchDescendants(of: a, containing: point, depth: searchDepth, budget: &budget) { return found }
            if budget <= 0 { break }
            ancestor = a.parent
        }
        return nil
    }

    private static func searchDescendants<N: AccessibilityNode>(of node: N, containing point: CGPoint,
                                                                depth: Int, budget: inout Int) -> N? {
        guard depth > 0 else { return nil }
        for child in node.children {
            guard budget > 0 else { return nil }
            budget -= 1
            guard let frame = child.frame, frame.insetBy(dx: -2, dy: -2).contains(point) else { continue }
            if isTextInput(child) { return child }
            if let found = searchDescendants(of: child, containing: point, depth: depth - 1, budget: &budget) { return found }
        }
        return nil
    }
}
