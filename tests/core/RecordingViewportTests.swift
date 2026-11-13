import CoreGraphics
import XCTest
@testable import FairyCore

final class RecordingViewportTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func settle(_ v: inout RecordingViewport, cursor: CGPoint, seconds: Double = 2) {
        for _ in 0..<Int(seconds * 60) { v.step(cursor: cursor, dt: 1.0 / 60) }
    }

    func testStartsShowingTheWholeDisplay() {
        let v = RecordingViewport(display: display)
        XCTAssertEqual(v.area, display)
    }

    func testZoomEasesTowardTarget() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(2))
        XCTAssertEqual(v.targetZoom, 2, accuracy: 0.0001)
        v.step(cursor: CGPoint(x: 800, y: 500), dt: 1.0 / 60)
        XCTAssertGreaterThan(v.zoom, 1)
        XCTAssertLessThan(v.zoom, 2, "one frame is not the whole way")
        settle(&v, cursor: CGPoint(x: 800, y: 500))
        XCTAssertEqual(v.zoom, 2, accuracy: 0.001)
        XCTAssertEqual(v.area.width, 800, accuracy: 1)
        XCTAssertEqual(v.area.height, 500, accuracy: 1)
    }

    func testZoomIsClamped() {
        var v = RecordingViewport(display: display)
        v.zoom(by: -5)
        XCTAssertEqual(v.targetZoom, 1)
        v.zoom(by: 50)
        XCTAssertEqual(v.targetZoom, 4)
    }

    func testAreaStaysOnTheDisplay() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(3))
        settle(&v, cursor: CGPoint(x: 1, y: 1))
        XCTAssertGreaterThanOrEqual(v.area.minX, display.minX - 0.001)
        XCTAssertGreaterThanOrEqual(v.area.minY, display.minY - 0.001)
        settle(&v, cursor: CGPoint(x: 1599, y: 999))
        XCTAssertLessThanOrEqual(v.area.maxX, display.maxX + 0.001)
        XCTAssertLessThanOrEqual(v.area.maxY, display.maxY + 0.001)
    }

    func testAreaFollowsTheCursorWhenItNearsTheEdge() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(2))
        settle(&v, cursor: CGPoint(x: 800, y: 500))
        let before = v.area
        settle(&v, cursor: CGPoint(x: 820, y: 510))
        XCTAssertEqual(v.area.midX, before.midX, accuracy: 0.5, "small moves in the middle don't move the area")
        settle(&v, cursor: CGPoint(x: 1300, y: 500))
        XCTAssertTrue(v.area.contains(CGPoint(x: 1300, y: 500)))
        XCTAssertGreaterThan(v.area.midX, before.midX)
    }

    func testDisplayWithOffsetOrigin() {
        let left = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        var v = RecordingViewport(display: left)
        v.zoom(by: log(2))
        settle(&v, cursor: CGPoint(x: -1900, y: -280))
        XCTAssertEqual(v.area.minX, left.minX, accuracy: 0.5)
        XCTAssertEqual(v.area.minY, left.minY, accuracy: 0.5)
    }
}
