import CoreGraphics
import Foundation
import XCTest
@testable import FairyCore

final class ShakeGateTests: XCTestCase {
    private func run(_ gate: ShakeGate, _ path: Motion.Path, holding: Bool = true) -> [ShakeGesture.Result] {
        path.map { gate.move(x: $0.x, y: $0.y, at: $0.t, holding: holding) }.filter { $0 != .none }
    }

    func testShakeWhileHoldingDiscards() {
        let gate = ShakeGate()
        XCTAssertEqual(run(gate, Motion.shake(amplitude: 60, hz: 3, duration: 1.0)), [.discardTop])
    }

    func testNothingHeldNeverDiscards() {
        let gate = ShakeGate()
        XCTAssertEqual(run(gate, Motion.shake(amplitude: 60, hz: 3, duration: 1.0), holding: false), [])
    }

    func testPickingAWindowDuringCmdShift4NeverDiscards() {
        // ⌘⇧4, Space, then sweeping back and forth across windows to choose one.
        let gate = ShakeGate()
        gate.screenshotUIShown()
        XCTAssertEqual(run(gate, Motion.shake(amplitude: 300, hz: 2.5, duration: 3)), [])
        XCTAssertEqual(run(gate, Motion.shake(amplitude: 60, hz: 4, duration: 2, start: 3.1)), [])
    }

    func testMovementDuringCaptureDoesNotCarryOverAfterwards() {
        let gate = ShakeGate()
        gate.screenshotUIShown()
        _ = run(gate, Motion.shake(amplitude: 60, hz: 3, duration: 0.6))
        gate.screenshotUIGone()
        gate.captured()
        // Half a shake right after the capture is not enough.
        XCTAssertEqual(run(gate, Motion.shake(amplitude: 60, hz: 3, duration: 0.4, start: 0.62)), [])
    }

    func testPartialShakeBeforeCaptureDoesNotCombineWithAfter() {
        let gate = ShakeGate()
        _ = run(gate, Motion.shake(amplitude: 60, hz: 3, duration: 0.55))
        gate.captured()
        XCTAssertEqual(run(gate, Motion.shake(amplitude: 60, hz: 3, duration: 0.35, start: 0.56)), [])
    }

    func testShakeWorksAgainOnceTheCaptureUIIsGone() {
        let gate = ShakeGate()
        gate.screenshotUIShown()
        gate.screenshotUIGone()
        XCTAssertEqual(run(gate, Motion.shake(amplitude: 60, hz: 3, duration: 1.0)), [.discardTop])
    }
}
