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

final class CanvasPolicyTests: XCTestCase {
    private let page = CGRect(x: 0, y: 160, width: 1800, height: 1009)

    func testWebCanvasFillingThePageIsACanvas() {
        // Excalidraw in Chrome: the <canvas> is an AXImage as big as the page.
        let spot = CanvasPolicy.Spot(role: "AXImage", ancestorRoles: ["AXGroup", "AXGroup", "AXWebArea", "AXScrollArea", "AXWindow"],
                                     frame: page, webAreaFrame: page, url: "https://example.org/board", bundleID: "com.google.Chrome")
        XCTAssertTrue(CanvasPolicy.isCanvas(spot))
    }

    func testAnOrdinaryPictureInAPageIsNot() {
        let photo = CGRect(x: 300, y: 300, width: 600, height: 400)
        let spot = CanvasPolicy.Spot(role: "AXImage", ancestorRoles: ["AXGroup", "AXWebArea"], frame: photo, webAreaFrame: page,
                                     url: "https://news.example.com/story", bundleID: "com.google.Chrome")
        XCTAssertFalse(CanvasPolicy.isCanvas(spot))
    }

    func testAPictureInsideALinkIsNot() {
        let spot = CanvasPolicy.Spot(role: "AXImage", ancestorRoles: ["AXLink", "AXWebArea"], frame: page, webAreaFrame: page)
        XCTAssertFalse(CanvasPolicy.isCanvas(spot))
    }

    func testKnownCanvasSites() {
        XCTAssertTrue(CanvasPolicy.isKnownCanvasApp(bundleID: "com.google.Chrome", url: "https://www.figma.com/design/abc/File?node-id=1"))
        XCTAssertTrue(CanvasPolicy.isKnownCanvasApp(bundleID: "com.apple.Safari", url: "https://docs.google.com/presentation/d/abc/edit#slide=1"))
        XCTAssertTrue(CanvasPolicy.isKnownCanvasApp(bundleID: nil, url: "https://app.excalidraw.com/x"))
        XCTAssertFalse(CanvasPolicy.isKnownCanvasApp(bundleID: "com.google.Chrome", url: "https://docs.google.com/spreadsheets/d/abc"))
        XCTAssertFalse(CanvasPolicy.isKnownCanvasApp(bundleID: "com.google.Chrome", url: "https://notfigma.com/"))
        XCTAssertTrue(CanvasPolicy.isKnownCanvasApp(bundleID: "com.figma.Desktop", url: nil))
        XCTAssertTrue(CanvasPolicy.isKnownCanvasApp(bundleID: "com.apple.iWork.Keynote", url: nil))
    }

    func testGoogleDocsIsADropTargetThatKeepsItsSelectionRules() {
        let url = "https://docs.google.com/document/d/abc/edit?tab=t.0"
        XCTAssertTrue(CanvasPolicy.isKnownCanvasApp(bundleID: "com.google.Chrome", url: url))
        XCTAssertTrue(CanvasPolicy.isPageDrawnDocument(url: url))
        XCTAssertTrue(CanvasPolicy.isCanvas(.init(role: "AXGroup", ancestorRoles: ["AXGroup", "AXWebArea"], url: url)))
        XCTAssertFalse(CanvasPolicy.isCanvas(.init(role: "AXButton", ancestorRoles: ["AXToolbar", "AXWebArea"], url: url)))
        // Slides and boards have no word selection to protect.
        XCTAssertFalse(CanvasPolicy.isPageDrawnDocument(url: "https://docs.google.com/presentation/d/abc/edit"))
        XCTAssertFalse(CanvasPolicy.isPageDrawnDocument(url: nil))
    }

    func testSlidesSurfaceIsACanvasButItsFilmstripAndButtonsAreNot() {
        let url = "https://docs.google.com/presentation/d/abc/edit"
        XCTAssertTrue(CanvasPolicy.isCanvas(.init(role: "AXGroup", ancestorRoles: ["AXGroup", "AXWebArea"], url: url)))
        XCTAssertFalse(CanvasPolicy.isCanvas(.init(role: "AXButton", ancestorRoles: ["AXToolbar", "AXWebArea"], url: url)))
        XCTAssertFalse(CanvasPolicy.isCanvas(.init(role: "AXGroup", ancestorRoles: ["AXToolbar", "AXWebArea"], url: url)))
        XCTAssertFalse(CanvasPolicy.isCanvas(.init(role: "AXStaticText", ancestorRoles: ["AXGroup", "AXWebArea"], url: url)))
    }

    func testKeynote() {
        XCTAssertTrue(CanvasPolicy.isCanvas(.init(role: "AXLayoutArea", ancestorRoles: ["AXScrollArea", "AXSplitGroup", "AXWindow"], bundleID: "com.apple.iWork.Keynote")))
        // The slide navigator is an outline: a double-click there is not a drop.
        XCTAssertFalse(CanvasPolicy.isCanvas(.init(role: "AXGroup", ancestorRoles: ["AXRow", "AXOutline", "AXWindow"], bundleID: "com.apple.iWork.Keynote")))
        XCTAssertFalse(CanvasPolicy.isCanvas(.init(role: "AXWindow", bundleID: "com.apple.iWork.Keynote")))
    }

    func testAPlainWindowBackgroundIsNotACanvas() {
        XCTAssertFalse(CanvasPolicy.isCanvas(.init(role: "AXGroup", ancestorRoles: ["AXWindow"], bundleID: "com.apple.mail")))
        XCTAssertFalse(CanvasPolicy.isCanvas(.init(role: nil)))
    }

    func testCanvasDropNeedsTypingNotToBeGoingElsewhere() {
        let point = CGPoint(x: 900, y: 600)
        let composer = CGRect(x: 400, y: 950, width: 800, height: 60)
        XCTAssertTrue(DropPolicy.confirmCanvasDrop(point: point, canvasSpot: true, knownCanvasApp: false, focusedEditable: false, focusedFrame: nil))
        XCTAssertFalse(DropPolicy.confirmCanvasDrop(point: point, canvasSpot: true, knownCanvasApp: false, focusedEditable: true, focusedFrame: composer),
                       "a visible focused field would receive the ⌘V instead")
        XCTAssertTrue(DropPolicy.confirmCanvasDrop(point: point, canvasSpot: true, knownCanvasApp: false, focusedEditable: true,
                                                   focusedFrame: CGRect(x: -10000, y: 0, width: 1, height: 1)),
                      "the hidden field canvas apps use to catch typing")
        XCTAssertTrue(DropPolicy.confirmCanvasDrop(point: point, canvasSpot: true, knownCanvasApp: true, focusedEditable: true, focusedFrame: composer))
        XCTAssertFalse(DropPolicy.confirmCanvasDrop(point: point, canvasSpot: false, knownCanvasApp: true, focusedEditable: false, focusedFrame: nil))
    }

    func testABusyTerminalStillTakesThePaste() {
        XCTAssertEqual(DropPolicy.decide(.init(isHolding: true, silentTerminal: true)), .paste)
        XCTAssertEqual(DropPolicy.decide(.init(isHolding: false, silentTerminal: true)), .ignore)
    }
}
