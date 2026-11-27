import XCTest
@testable import FairyCore

final class FollowMotionTests: XCTestCase {
    /// Run toward (100, 0) from rest at the origin, 120 frames a second; returns every x on the way.
    private func run(_ style: FollowStyle, seconds: Double = 2) -> (motion: FollowMotion, xs: [Double], leans: [Double]) {
        var motion = FollowMotion(style: style)
        motion.jump(toX: 0, y: 0)
        var xs: [Double] = [], leans: [Double] = []
        for _ in 0..<Int(seconds * 120) {
            motion.step(towardX: 100, y: 0, dt: 1.0 / 120)
            xs.append(motion.x)
            leans.append(motion.lean)
        }
        return (motion, xs, leans)
    }

    func testCalmArrivesWithoutPassingTheTarget() {
        let (motion, xs, leans) = run(.calm)
        XCTAssertLessThanOrEqual(xs.max()!, 100)
        XCTAssertEqual(motion.x, 100, accuracy: 0.01)
        XCTAssertTrue(leans.allSatisfy { $0 == 0 })
    }

    func testCloseIsFasterThanCalm() {
        let close = run(.close, seconds: 0.05).motion.x
        let calm = run(.calm, seconds: 0.05).motion.x
        XCTAssertGreaterThan(close, calm)
        XCTAssertLessThanOrEqual(close, 100)
    }

    func testLivelySwingsPastOnceAndSettles() {
        let (motion, xs, _) = run(.lively, seconds: 3)
        let peak = xs.max()!
        XCTAssertGreaterThan(peak, 102)          // it does pass the target…
        XCTAssertLessThan(peak, 112)             // …by a little, not a bounce
        XCTAssertEqual(motion.x, 100, accuracy: 0.05)
        XCTAssertEqual(motion.lean, 0, accuracy: 0.05)
    }

    func testLivelyLeansIntoTheMoveAndNoFurtherThanTheLimit() {
        var motion = FollowMotion(style: .lively)
        motion.jump(toX: 0, y: 0)
        var most = 0.0
        for frame in 1...240 {
            motion.step(towardX: Double(frame) * 12, y: 0, dt: 1.0 / 120)   // the cursor sweeps right, fast
            most = max(most, motion.lean)
            XCTAssertGreaterThanOrEqual(motion.lean, -0.001)   // never leans against the move
        }
        XCTAssertGreaterThan(most, 5)
        XCTAssertLessThan(most, FollowMotion.leanLimit * 1.35)  // the spring may pass the limit a touch
    }

    func testSameResultWhateverTheFrameRate() {
        var smooth = FollowMotion(style: .lively), choppy = FollowMotion(style: .lively)
        for _ in 0..<120 { smooth.step(towardX: 100, y: 50, dt: 1.0 / 120) }
        for _ in 0..<30 { choppy.step(towardX: 100, y: 50, dt: 1.0 / 30) }
        XCTAssertEqual(smooth.x, choppy.x, accuracy: 0.5)
        XCTAssertEqual(smooth.y, choppy.y, accuracy: 0.5)
    }

    func testSwitchingToCalmStraightensUp() {
        var motion = FollowMotion(style: .lively)
        for _ in 0..<20 { motion.step(towardX: 2000, y: 0, dt: 1.0 / 120) }
        XCTAssertGreaterThan(motion.lean, 1)
        motion.style = .calm
        for _ in 0..<120 { motion.step(towardX: 2000, y: 0, dt: 1.0 / 120) }
        XCTAssertEqual(motion.lean, 0, accuracy: 0.01)
    }

    func testJumpLandsAtRest() {
        var motion = FollowMotion(style: .lively)
        for _ in 0..<20 { motion.step(towardX: 2000, y: 0, dt: 1.0 / 120) }
        motion.jump(toX: 7, y: 9)
        motion.step(towardX: 7, y: 9, dt: 1.0 / 120)
        XCTAssertEqual(motion.x, 7, accuracy: 0.001)
        XCTAssertEqual(motion.y, 9, accuracy: 0.001)
        XCTAssertEqual(motion.lean, 0, accuracy: 0.001)
    }
}
