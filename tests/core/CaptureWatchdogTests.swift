import Foundation
import XCTest
@testable import FairyCore

final class CaptureWatchdogTests: XCTestCase {
    func testOverlaySeenThenGoneTurnsStale() {
        var w = CaptureWatchdog()
        w.sessionStarted(interactive: true)
        XCTAssertFalse(w.observe(overlayVisible: true, at: 0.0))
        XCTAssertFalse(w.observe(overlayVisible: false, at: 1.0))
        XCTAssertFalse(w.observe(overlayVisible: false, at: 2.5))
        XCTAssertTrue(w.observe(overlayVisible: false, at: 4.0))
        XCTAssertTrue(w.isStale)
        XCTAssertFalse(w.observe(overlayVisible: false, at: 5.0), "fires once")
    }

    func testOverlayNeverSeenNeverFires() {
        var w = CaptureWatchdog()
        w.sessionStarted(interactive: true)
        for i in 0..<100 { XCTAssertFalse(w.observe(overlayVisible: false, at: Double(i))) }
    }

    func testFlickerDoesNotFire() {
        var w = CaptureWatchdog()
        w.sessionStarted(interactive: true)
        _ = w.observe(overlayVisible: true, at: 0)
        XCTAssertFalse(w.observe(overlayVisible: false, at: 2.0))
        XCTAssertFalse(w.observe(overlayVisible: true, at: 2.9))
        XCTAssertFalse(w.observe(overlayVisible: false, at: 3.2))
        XCTAssertFalse(w.observe(overlayVisible: false, at: 6.0))
        XCTAssertTrue(w.observe(overlayVisible: false, at: 6.2))
    }

    func testSlowRealCaptureAfterSelectionIsNotDeclaredStale() {
        // Mouse-up at 5.0 removes the overlay; the monitor's ScreenCaptureKit capture arrives
        // 1.5 s later and ends the session.
        var w = CaptureWatchdog()
        w.sessionStarted(interactive: true)
        for k in 0..<20 { _ = w.observe(overlayVisible: true, at: Double(k) * 0.25) }
        for k in 0..<6 { XCTAssertFalse(w.observe(overlayVisible: false, at: 5.0 + Double(k) * 0.25)) }
        XCTAssertFalse(w.isStale)
        w.sessionEnded()
    }

    func testNonInteractiveSessionsAreNotWatched() {
        var w = CaptureWatchdog()
        w.sessionStarted(interactive: false)
        _ = w.observe(overlayVisible: true, at: 0)
        XCTAssertFalse(w.observe(overlayVisible: false, at: 5))
    }

    func testEndResetsAndNewSessionStartsClean() {
        var w = CaptureWatchdog()
        w.sessionStarted(interactive: true)
        _ = w.observe(overlayVisible: true, at: 0)
        XCTAssertFalse(w.observe(overlayVisible: false, at: 1))
        XCTAssertTrue(w.observe(overlayVisible: false, at: 4.5))
        w.sessionEnded()
        XCTAssertFalse(w.isStale)
        XCTAssertFalse(w.isWatching)
        w.sessionStarted(interactive: true)
        XCTAssertFalse(w.observe(overlayVisible: false, at: 10), "previous sighting does not carry over")
    }

    func testNotWatchingWithoutSession() {
        var w = CaptureWatchdog()
        XCTAssertFalse(w.observe(overlayVisible: true, at: 0))
        XCTAssertFalse(w.observe(overlayVisible: false, at: 5))
    }
}
