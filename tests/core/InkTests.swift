import CoreGraphics
import XCTest
@testable import FairyCore

final class InkTests: XCTestCase {
    func testShortcutTakesToolAndPressingAgainPutsItDown() {
        var ink = Ink()
        XCTAssertTrue(ink.press(.pen))
        XCTAssertEqual(ink.tool, .pen)
        XCTAssertTrue(ink.press(.pen))
        XCTAssertNil(ink.tool)
    }

    func testOtherShortcutSwitchesToolAndKeepsTheInk() {
        var ink = Ink()
        ink.press(.pen)
        drawLine(&ink)
        ink.press(.highlighter)
        XCTAssertEqual(ink.tool, .highlighter)
        XCTAssertEqual(ink.strokes.count, 1)
        XCTAssertEqual(ink.strokes[0].tool, .pen)
        drawLine(&ink)
        XCTAssertEqual(ink.strokes.map(\.tool), [.pen, .highlighter])
    }

    func testDonePutsToolDownAndWipesTheInk() {
        var ink = Ink()
        ink.press(.highlighter)
        drawLine(&ink)
        XCTAssertTrue(ink.press(.done))
        XCTAssertNil(ink.tool)
        XCTAssertTrue(ink.strokes.isEmpty)
    }

    func testEditingKeysAreLeftAloneWhenNotDrawing() {
        // esc, ⌘Z and ⌫ belong to the app underneath unless a tool is in hand.
        var ink = Ink()
        XCTAssertFalse(ink.press(.done))
        XCTAssertFalse(ink.press(.undo))
        XCTAssertFalse(ink.press(.clear))
    }

    func testUndoTakesBackTheLastStroke() {
        var ink = Ink()
        ink.press(.pen)
        drawLine(&ink)
        drawLine(&ink, y: 50)
        XCTAssertTrue(ink.press(.undo))
        XCTAssertEqual(ink.strokes.count, 1)
        XCTAssertTrue(ink.press(.undo))
        XCTAssertTrue(ink.strokes.isEmpty)
        XCTAssertTrue(ink.press(.undo), "still drawing: the key is ours even with nothing to undo")
    }

    func testClearWipesButKeepsTheTool() {
        var ink = Ink()
        ink.press(.pen)
        drawLine(&ink)
        ink.press(.clear)
        XCTAssertTrue(ink.strokes.isEmpty)
        XCTAssertEqual(ink.tool, .pen)
    }

    func testNoStrokesWithoutATool() {
        var ink = Ink()
        ink.beginStroke(at: .zero)
        ink.extendStroke(to: CGPoint(x: 10, y: 0))
        ink.endStroke()
        XCTAssertTrue(ink.strokes.isEmpty)
    }

    func testTinyMovesAreDropped() {
        var ink = Ink()
        ink.press(.pen)
        ink.beginStroke(at: .zero)
        ink.extendStroke(to: CGPoint(x: 0.5, y: 0.5))
        ink.extendStroke(to: CGPoint(x: 5, y: 0))
        XCTAssertEqual(ink.current?.points.count, 2)
    }

    func testAClickMakesARoundDot() {
        let shape = Ink.shape(of: Ink.Stroke(tool: .pen, points: [CGPoint(x: 100, y: 100)]), complete: true)
        let box = shape.boundingBoxOfPath
        XCTAssertFalse(shape.isEmpty)
        XCTAssertTrue(box.contains(CGPoint(x: 100, y: 100)))
        XCTAssertEqual(box.width, box.height, accuracy: 1.5)
    }

    func testCompletedStrokeCoversItsEnds() {
        let points = (0...30).map { CGPoint(x: CGFloat($0) * 6, y: 50 + sin(CGFloat($0) / 4) * 20) }
        let shape = Ink.shape(of: Ink.Stroke(tool: .pen, points: points), complete: true)
        XCTAssertTrue(shape.contains(points[0]))
        XCTAssertTrue(shape.contains(points.last!))
        XCTAssertTrue(shape.contains(points[15]))
    }

    func testPenThinsWhenFastAndHighlighterDoesNot() {
        // Same distance, drawn slowly (many close points) and quickly (few far apart).
        func width(_ tool: InkTool, step: CGFloat) -> CGFloat {
            let points = stride(from: 0, through: 300, by: step).map { CGPoint(x: $0, y: 100) }
            return Ink.shape(of: Ink.Stroke(tool: tool, points: points), complete: true)
                .boundingBoxOfPath.height
        }
        XCTAssertGreaterThan(width(.pen, step: 2), width(.pen, step: 30) + 1)
        XCTAssertEqual(width(.highlighter, step: 2), width(.highlighter, step: 30), accuracy: 1)
    }

    private func drawLine(_ ink: inout Ink, y: CGFloat = 10) {
        ink.beginStroke(at: CGPoint(x: 0, y: y))
        ink.extendStroke(to: CGPoint(x: 40, y: y))
        ink.extendStroke(to: CGPoint(x: 80, y: y + 5))
        ink.endStroke()
    }
}
