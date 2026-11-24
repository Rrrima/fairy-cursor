import CoreGraphics
import XCTest
@testable import FairyCore

final class RecordingViewportTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func settle(_ v: inout RecordingViewport, cursor: CGPoint, following: Bool = true, seconds: Double = 2) {
        for _ in 0..<Int(seconds * 60) { v.step(cursor: cursor, following: following, dt: 1.0 / 60) }
    }

    func testStartsShowingTheWholeDisplay() {
        let v = RecordingViewport(display: display)
        XCTAssertEqual(v.area, display)
    }

    func testZoomEasesTowardTarget() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(2))
        XCTAssertEqual(v.targetZoom, 2, accuracy: 0.0001)
        v.step(cursor: CGPoint(x: 800, y: 500), following: false, dt: 1.0 / 60)
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

    func testAreaStaysPutWithoutOption() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(2))
        settle(&v, cursor: CGPoint(x: 800, y: 500))
        let before = v.area
        settle(&v, cursor: CGPoint(x: 1500, y: 900), following: false)
        XCTAssertEqual(v.area.midX, before.midX, accuracy: 0.001, "letting go of ⌥ pins the area")
        XCTAssertEqual(v.area.midY, before.midY, accuracy: 0.001)
    }

    func testAreaCentresOnTheCursorWhileOptionIsHeld() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(2))
        settle(&v, cursor: CGPoint(x: 800, y: 500))
        settle(&v, cursor: CGPoint(x: 700, y: 450))
        XCTAssertEqual(v.area.midX, 700, accuracy: 1)
        XCTAssertEqual(v.area.midY, 450, accuracy: 1)
    }

    func testLettingGoOfOptionStopsTheAreaAtOnce() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(2))
        settle(&v, cursor: CGPoint(x: 800, y: 500))
        for _ in 0..<6 { v.step(cursor: CGPoint(x: 1300, y: 800), following: true, dt: 1.0 / 60) }
        let atRelease = v.area
        XCTAssertGreaterThan(atRelease.midX, 800, "it started moving")
        settle(&v, cursor: CGPoint(x: 1300, y: 800), following: false)
        XCTAssertEqual(v.area.midX, atRelease.midX, accuracy: 0.001, "no glide after ⌥ is released")
        XCTAssertEqual(v.area.midY, atRelease.midY, accuracy: 0.001)
    }

    func testZoomStillEasesWhilePinned() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(2))
        settle(&v, cursor: CGPoint(x: 400, y: 300), following: false)
        XCTAssertEqual(v.zoom, 2, accuracy: 0.001)
        XCTAssertEqual(v.area.midX, 800, accuracy: 1, "zooms around where the area already is")
    }

    func testResetEasesBackToTheWholeDisplay() {
        var v = RecordingViewport(display: display)
        v.zoom(by: log(3))
        settle(&v, cursor: CGPoint(x: 1300, y: 800))
        v.reset()
        XCTAssertEqual(v.targetZoom, 1)
        v.step(cursor: CGPoint(x: 1300, y: 800), following: false, dt: 1.0 / 60)
        XCTAssertGreaterThan(v.zoom, 1, "one frame is not the whole way")
        XCTAssertTrue(display.contains(v.area), "stays on the display on the way out")
        settle(&v, cursor: CGPoint(x: 1300, y: 800), following: false)
        XCTAssertEqual(v.area, display)
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
