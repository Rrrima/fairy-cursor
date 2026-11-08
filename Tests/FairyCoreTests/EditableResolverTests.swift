import CoreGraphics
import Foundation
import XCTest
@testable import FairyCore

/// In-memory accessibility tree.
final class Node: AccessibilityNode {
    let role: String?
    let subrole: String?
    let frame: CGRect?
    var parentNode: Node?   // strong on purpose: trees are built inline and must stay alive (tests only)
    var kids: [Node] = []
    let hasEditableAncestorAttribute: Bool
    let isSettableTextValue: Bool

    init(_ role: String?, subrole: String? = nil, frame: CGRect? = nil, editableAncestor: Bool = false,
         settableText: Bool = false, _ kids: [Node] = []) {
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.hasEditableAncestorAttribute = editableAncestor
        self.isSettableTextValue = settableText
        self.kids = kids
        kids.forEach { $0.parentNode = self }
    }

    var parent: Node? { parentNode }
    var children: [Node] { kids }
}

final class EditableResolverTests: XCTestCase {
    func testNativeRoles() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(EditableResolver.isTextInput(Node(role)), role)
        }
        XCTAssertFalse(EditableResolver.isTextInput(Node("AXButton")))
        XCTAssertFalse(EditableResolver.isTextInput(Node("AXStaticText")))
    }

    func testSecureFieldIsNotAPasteTarget() {
        XCTAssertFalse(EditableResolver.isTextInput(Node("AXTextField", subrole: "AXSecureTextField")))
    }

    func testChromiumEditableAncestorAttribute() {
        XCTAssertTrue(EditableResolver.isTextInput(Node("AXGroup", editableAncestor: true)))
    }

    func testCustomTextViewWithGenericRole() {
        // SwiftUI/Catalyst/canvas editors: a group whose value is settable text.
        XCTAssertTrue(EditableResolver.isTextInput(Node("AXGroup", settableText: true)))
        XCTAssertTrue(EditableResolver.isTextInput(Node(nil, settableText: true)))
    }

    func testSettableNonTextControlsAreNotText() {
        XCTAssertFalse(EditableResolver.isTextInput(Node("AXSlider", settableText: true)))
        XCTAssertFalse(EditableResolver.isTextInput(Node("AXCheckBox", settableText: true)))
    }

    func testStaticTextInsideTextAreaResolvesToAncestor() {
        let text = Node("AXStaticText")
        let area = Node("AXTextArea", [Node("AXGroup", [text])])
        _ = Node("AXWindow", [area])
        XCTAssertTrue(EditableResolver.editableSelfOrAncestor(text) === area)
    }

    func testAncestorWalkStopsAtWebArea() {
        let text = Node("AXStaticText")
        _ = Node("AXTextArea", [Node("AXWebArea", [Node("AXGroup", [text])])])
        XCTAssertNil(EditableResolver.editableSelfOrAncestor(text))
    }

    func testPlaceholderOverComposerResolvesToSiblingTextView() {
        // The ChatGPT-style empty composer: "Ask anything" is a static text drawn on top of the
        // text view, so hit-testing returns the label.
        let composerFrame = CGRect(x: 400, y: 900, width: 700, height: 60)
        let placeholder = Node("AXStaticText", frame: CGRect(x: 412, y: 915, width: 120, height: 20))
        let textView = Node("AXTextArea", frame: composerFrame)
        let attach = Node("AXButton", frame: CGRect(x: 360, y: 910, width: 30, height: 30))
        let send = Node("AXButton", frame: CGRect(x: 1110, y: 910, width: 30, height: 30))
        _ = Node("AXWindow", [Node("AXGroup", frame: CGRect(x: 350, y: 890, width: 800, height: 80), [attach, Node("AXGroup", frame: composerFrame, [textView, placeholder]), send])])
        let found = EditableResolver.editableTarget(at: CGPoint(x: 450, y: 925), hit: placeholder)
        XCTAssertTrue(found === textView)
    }

    func testScrollViewPaddingAroundTextViewResolves() {
        let textView = Node("AXTextArea", frame: CGRect(x: 100, y: 100, width: 300, height: 40))
        let scroll = Node("AXScrollArea", frame: CGRect(x: 90, y: 90, width: 320, height: 60), [textView])
        _ = Node("AXWindow", [Node("AXGroup", [scroll])])
        // Click lands on the scroll area's inset, outside the text view: the text view does not
        // contain the point, so nothing is found by geometry…
        XCTAssertNil(EditableResolver.editableTarget(at: CGPoint(x: 95, y: 95), hit: scroll))
        // …but inside it, it is.
        XCTAssertTrue(EditableResolver.editableTarget(at: CGPoint(x: 120, y: 110), hit: scroll) === textView)
    }

    func testButtonNextToComposerDoesNotResolve() {
        let textView = Node("AXTextArea", frame: CGRect(x: 400, y: 900, width: 700, height: 60))
        let send = Node("AXButton", frame: CGRect(x: 1110, y: 910, width: 30, height: 30))
        _ = Node("AXWindow", [Node("AXGroup", [textView, send])])
        XCTAssertNil(EditableResolver.editableTarget(at: CGPoint(x: 1120, y: 920), hit: send))
    }

    func testSearchDoesNotCrossTheWindow() {
        let field = Node("AXTextField", frame: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let label = Node("AXStaticText", frame: CGRect(x: 10, y: 10, width: 10, height: 10))
        _ = Node("AXApplication", [Node("AXWindow", [field]), Node("AXWindow", [label])])
        XCTAssertNil(EditableResolver.editableTarget(at: CGPoint(x: 15, y: 15), hit: label))
    }

    func testNodeBudgetBoundsTheSearch() {
        let label = Node("AXStaticText", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        var siblings = (0..<500).map { _ in Node("AXButton", frame: CGRect(x: 0, y: 0, width: 50, height: 50)) }
        let field = Node("AXTextArea", frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        siblings.append(field)
        siblings.append(label)
        _ = Node("AXWindow", [Node("AXGroup", siblings)])
        XCTAssertNil(EditableResolver.editableTarget(at: CGPoint(x: 5, y: 5), hit: label, nodeBudget: 80))
    }

    func testCycleSafeAncestorWalk() {
        // Depth-bounded even on a very deep tree.
        var node = Node("AXGroup")
        let leaf = node
        for _ in 0..<50 { node = Node("AXGroup", [node]) }
        XCTAssertNil(EditableResolver.editableSelfOrAncestor(leaf))
    }
}
