import CoreGraphics
import Foundation
import XCTest
@testable import FairyCore

final class DropPolicyTests: XCTestCase {
    private typealias DC = DropPolicy.DoubleClick

    func testNothingHeldIgnores() {
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: false, editableUnderCursor: true)), .ignore)
    }

    func testHiddenForCaptureIgnores() {
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, hiddenForCapture: true, editableUnderCursor: true)), .ignore)
    }

    func testBusyIgnores() {
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, busy: true, editableUnderCursor: true)), .ignore)
    }

    func testTripleClickIgnored() {
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, clickCount: 3, editableUnderCursor: true)), .ignore)
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, clickCount: 1, editableUnderCursor: true)), .ignore)
    }

    func testOwnNoteIgnored() {
        // Notes take the pile through their own double-click handler; the router must not also
        // paste into them (double delivery, ⌘V into ourselves).
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, targetIsOwnProcess: true, editableUnderCursor: true)), .ignore)
    }

    func testFinderDropSpotSaves() {
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, isFinder: true, finderDropSpot: true)), .saveToFinder)
    }

    func testFinderItemOrSearchFieldIgnored() {
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, isFinder: true, finderDropSpot: false)), .ignore)
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, isFinder: true, finderDropSpot: false, editableUnderCursor: true)), .ignore)
    }

    func testEditablePastes() {
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true, editableUnderCursor: true)), .paste)
    }

    func testUnrecognisedElementInAnyAppChecksFocus() {
        // Previously only Chromium apps got a second look; native composers (ChatGPT, Messages
        // under a placeholder) were dropped on the floor.
        XCTAssertEqual(DropPolicy.decide(DC(isHolding: true)), .checkFocusAfterMouseUp)
    }

    // MARK: Confirmation after mouse-up

    func testFocusedFieldContainingClickConfirms() {
        XCTAssertTrue(DropPolicy.confirmAfterMouseUp(point: CGPoint(x: 500, y: 900), hitEditable: false, focusedEditable: true,
                                                     focusedFrame: CGRect(x: 300, y: 860, width: 600, height: 80), nearbyEditable: false))
    }

    func testFocusedFieldElsewhereDoesNotConfirm() {
        // Double-click on a toolbar while a search field elsewhere has focus.
        XCTAssertFalse(DropPolicy.confirmAfterMouseUp(point: CGPoint(x: 500, y: 40), hitEditable: false, focusedEditable: true,
                                                      focusedFrame: CGRect(x: 300, y: 860, width: 600, height: 80), nearbyEditable: false))
    }

    func testFocusedFieldEdgeSlack() {
        XCTAssertTrue(DropPolicy.confirmAfterMouseUp(point: CGPoint(x: 297, y: 862), hitEditable: false, focusedEditable: true,
                                                     focusedFrame: CGRect(x: 300, y: 860, width: 600, height: 80), nearbyEditable: false))
        XCTAssertFalse(DropPolicy.confirmAfterMouseUp(point: CGPoint(x: 280, y: 862), hitEditable: false, focusedEditable: true,
                                                      focusedFrame: CGRect(x: 300, y: 860, width: 600, height: 80), nearbyEditable: false))
    }

    func testFocusedNonEditableDoesNotConfirm() {
        XCTAssertFalse(DropPolicy.confirmAfterMouseUp(point: .zero, hitEditable: false, focusedEditable: false,
                                                      focusedFrame: CGRect(x: -10, y: -10, width: 20, height: 20), nearbyEditable: false))
    }

    func testFocusedWithoutFrameDoesNotConfirm() {
        XCTAssertFalse(DropPolicy.confirmAfterMouseUp(point: .zero, hitEditable: false, focusedEditable: true, focusedFrame: nil, nearbyEditable: false))
    }

    func testLateHitOrNearbyConfirms() {
        XCTAssertTrue(DropPolicy.confirmAfterMouseUp(point: .zero, hitEditable: true, focusedEditable: false, focusedFrame: nil, nearbyEditable: false))
        XCTAssertTrue(DropPolicy.confirmAfterMouseUp(point: .zero, hitEditable: false, focusedEditable: false, focusedFrame: nil, nearbyEditable: true))
    }

    // MARK: Finder

    func testFinderBackgroundRoles() {
        for role in ["AXScrollArea", "AXGroup", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid"] {
            XCTAssertTrue(FinderDropPolicy.isDropSpot(role: role), role)
        }
    }

    func testFinderItemsAreNotDropSpots() {
        for role in ["AXImage", "AXTextField", "AXStaticText", "AXRow", "AXCell", "AXButton"] {
            XCTAssertFalse(FinderDropPolicy.isDropSpot(role: role), role)
        }
        XCTAssertFalse(FinderDropPolicy.isDropSpot(role: nil))
    }

    func testTitleBarDoubleClickIsNotADropSpot() {
        // Double-clicking a title bar zooms the window; it used to dump the pile into the folder.
        XCTAssertFalse(FinderDropPolicy.isDropSpot(role: "AXWindow"))
    }

    func testToolbarGroupIsNotADropSpot() {
        XCTAssertFalse(FinderDropPolicy.isDropSpot(role: "AXGroup", ancestorRoles: ["AXToolbar", "AXWindow"]))
        XCTAssertTrue(FinderDropPolicy.isDropSpot(role: "AXGroup", ancestorRoles: ["AXScrollArea", "AXSplitGroup", "AXWindow"]))
    }
}
