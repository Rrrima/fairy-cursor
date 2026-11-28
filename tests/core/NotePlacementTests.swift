import CoreGraphics
import XCTest
@testable import FairyCore

final class NotePlacementTests: XCTestCase {
    private let display = CGRect(x: -1200, y: 80, width: 1200, height: 800)
    private let cardSize = CGSize(width: 304, height: 224)
    private let pillSize = CGSize(width: 46, height: 34)

    private func placement(at cursor: CGPoint, in bounds: CGRect? = nil) -> NotePlacement {
        NotePlacement(cursor: cursor, cardSize: cardSize, pillSize: pillSize, visibleFrame: bounds ?? display)
    }

    func testGrowsRightAndDownWhenThereIsRoom() {
        let note = placement(at: CGPoint(x: -800, y: 500))
        XCTAssertEqual(note.cardFrame, CGRect(x: -823, y: 293, width: 304, height: 224))
        XCTAssertEqual(note.summonCenter, CGPoint(x: 23, y: 17))
    }

    func testGrowsLeftNearRightEdge() {
        let note = placement(at: CGPoint(x: -100, y: 500))
        XCTAssertEqual(note.cardFrame.maxX, -77)
        XCTAssertEqual(note.summonCenter, CGPoint(x: 281, y: 17))
        XCTAssertTrue(display.contains(note.cardFrame))
    }

    func testGrowsUpNearBottomEdge() {
        let note = placement(at: CGPoint(x: -800, y: 160))
        XCTAssertEqual(note.cardFrame.minY, 143)
        XCTAssertEqual(note.summonCenter, CGPoint(x: 23, y: 207))
        XCTAssertTrue(display.contains(note.cardFrame))
    }

    func testClampedCornerStillStartsAtTheCursor() {
        let cursor = CGPoint(x: -3, y: 82)
        let note = placement(at: cursor)
        XCTAssertEqual(note.cardFrame.maxX, display.maxX)
        XCTAssertEqual(note.cardFrame.minY, display.minY)
        XCTAssertEqual(CGPoint(x: note.cardFrame.minX + note.summonCenter.x,
                               y: note.cardFrame.maxY - note.summonCenter.y), cursor)
        XCTAssertTrue(display.contains(note.cardFrame))
    }

    func testClampsToVisibleAreaWhenNeitherDirectionFits() {
        let bounds = CGRect(x: 100, y: -100, width: 400, height: 300)
        let note = placement(at: CGPoint(x: 310, y: 40), in: bounds)
        XCTAssertEqual(note.cardFrame, CGRect(x: 100, y: -24, width: 304, height: 224))
        XCTAssertEqual(note.summonCenter, CGPoint(x: 210, y: 160))
    }
}
