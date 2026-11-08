import CoreGraphics
import Foundation
import XCTest
@testable import FairyCore

/// Synthetic cursor paths, sampled like a real mouse/trackpad stream.
enum Motion {
    typealias Path = [(t: TimeInterval, x: CGFloat, y: CGFloat)]

    /// Back-and-forth along `angle` (radians) with the given amplitude (points, half-stroke)
    /// and full cycles per second.
    static func shake(amplitude: CGFloat, hz: Double, duration: TimeInterval, angle: Double = 0,
                      rate: Double = 120, start: TimeInterval = 0, origin: CGPoint = CGPoint(x: 800, y: 500),
                      jitter: CGFloat = 0, seed: UInt64 = 1) -> Path {
        var rng = SeededRandom(seed: seed)
        var path: Path = []
        let n = Int(duration * rate)
        for i in 0...n {
            let t = Double(i) / rate
            let s = amplitude * CGFloat(sin(2 * .pi * hz * t))
            let jx = jitter > 0 ? CGFloat(rng.next(in: -1...1)) * jitter : 0
            let jy = jitter > 0 ? CGFloat(rng.next(in: -1...1)) * jitter : 0
            path.append((start + t, origin.x + s * CGFloat(cos(angle)) + jx, origin.y + s * CGFloat(sin(angle)) + jy))
        }
        return path
    }

    static func circle(radius: CGFloat, hz: Double, duration: TimeInterval, rate: Double = 120,
                       start: TimeInterval = 0, origin: CGPoint = CGPoint(x: 800, y: 500)) -> Path {
        var path: Path = []
        let n = Int(duration * rate)
        for i in 0...n {
            let t = Double(i) / rate
            let a = 2 * .pi * hz * t
            path.append((start + t, origin.x + radius * CGFloat(cos(a)), origin.y + radius * CGFloat(sin(a))))
        }
        return path
    }

    /// Straight moves between waypoints at a given speed (points/s), pausing `dwell` at each.
    static func waypoints(_ points: [CGPoint], speed: CGFloat, dwell: TimeInterval = 0, rate: Double = 120,
                          start: TimeInterval = 0) -> Path {
        var path: Path = []
        var t = start
        guard var current = points.first else { return [] }
        path.append((t, current.x, current.y))
        for next in points.dropFirst() {
            let d = hypot(next.x - current.x, next.y - current.y)
            let steps = max(Int(Double(d / speed) * rate), 1)
            for k in 1...steps {
                t += 1 / rate
                let f = CGFloat(k) / CGFloat(steps)
                path.append((t, current.x + (next.x - current.x) * f, current.y + (next.y - current.y) * f))
            }
            if dwell > 0 {
                let dwellSteps = Int(dwell * rate)
                for _ in 0..<dwellSteps { t += 1 / rate; path.append((t, next.x, next.y)) }
            }
            current = next
        }
        return path
    }

    static func feed(_ detector: ShakeDetector, _ path: Path) -> [TimeInterval] {
        var fired: [TimeInterval] = []
        for s in path where detector.feed(x: s.x, y: s.y, at: s.t) { fired.append(s.t) }
        return fired
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func nextUInt() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * Double(nextUInt() % 1_000_000) / 1_000_000
    }
}

final class ShakeDetectorTests: XCTestCase {
    // MARK: Deliberate shakes are detected

    func testHorizontalShakeFires() {
        let d = ShakeDetector()
        XCTAssertFalse(Motion.feed(d, Motion.shake(amplitude: 60, hz: 3, duration: 1.2)).isEmpty)
    }

    func testVerticalAndDiagonalShakesFire() {
        for angle in [Double.pi / 2, .pi / 4, -.pi / 3, 2.5] {
            let d = ShakeDetector()
            XCTAssertFalse(Motion.feed(d, Motion.shake(amplitude: 50, hz: 3.5, duration: 1.2, angle: angle)).isEmpty, "angle \(angle)")
        }
    }

    func testSmallQuickTrackpadWiggleFires() {
        // ±22 pt (44 pt strokes) at 4 Hz.
        let d = ShakeDetector()
        XCTAssertFalse(Motion.feed(d, Motion.shake(amplitude: 22, hz: 4, duration: 1.0)).isEmpty)
    }

    func testShakeWithHandJitterFires() {
        let d = ShakeDetector()
        XCTAssertFalse(Motion.feed(d, Motion.shake(amplitude: 50, hz: 3, duration: 1.3, jitter: 3, seed: 7)).isEmpty)
    }

    func testShakeAtHighPollingRateFires() {
        // 1000 Hz gaming mouse.
        let d = ShakeDetector()
        XCTAssertFalse(Motion.feed(d, Motion.shake(amplitude: 40, hz: 3, duration: 1.2, rate: 1000)).isEmpty)
    }

    func testShakeAtLowEventRateFires() {
        // Coalesced 30 Hz stream (busy main thread).
        let d = ShakeDetector()
        XCTAssertFalse(Motion.feed(d, Motion.shake(amplitude: 60, hz: 3, duration: 1.3, rate: 30)).isEmpty)
    }

    func testFiresOnlyOncePerCooldown() {
        let d = ShakeDetector()
        let fired = Motion.feed(d, Motion.shake(amplitude: 60, hz: 4, duration: 1.3))
        XCTAssertEqual(fired.count, 1, "\(fired)")
    }

    func testFiresAgainAfterCooldown() {
        let d = ShakeDetector()
        let fired = Motion.feed(d, Motion.shake(amplitude: 60, hz: 4, duration: 3.5))
        XCTAssertGreaterThanOrEqual(fired.count, 2)
        if fired.count >= 2 { XCTAssertGreaterThan(fired[1] - fired[0], d.cooldown) }
    }

    // MARK: Ordinary movement never fires

    func testSlowBackAndForthDoesNotFire() {
        // Reading / comparing two things: 100 pt strokes at 0.8 Hz.
        let d = ShakeDetector()
        XCTAssertTrue(Motion.feed(d, Motion.shake(amplitude: 100, hz: 0.8, duration: 5)).isEmpty)
    }

    func testTwoFastFlicksDoNotFire() {
        // Flick to a far corner and back, twice — only 3 reversals.
        let d = ShakeDetector()
        let a = CGPoint(x: 200, y: 300), b = CGPoint(x: 1400, y: 900)
        XCTAssertTrue(Motion.feed(d, Motion.waypoints([a, b, a, b, a], speed: 6000)).isEmpty)
    }

    func testCirclingDoesNotFire() {
        for radius in [CGFloat(30), 45, 80, 150] {
            for hz in [1.0, 2.0, 3.0] {
                let d = ShakeDetector()
                XCTAssertTrue(Motion.feed(d, Motion.circle(radius: radius, hz: hz, duration: 3)).isEmpty, "r=\(radius) hz=\(hz)")
            }
        }
    }

    func testStaircaseZigZagDoesNotFire() {
        // Moving down a list: right, down, left?, … 90° turns only.
        var pts: [CGPoint] = []
        var p = CGPoint(x: 400, y: 200)
        for i in 0..<12 {
            pts.append(p)
            p = i % 2 == 0 ? CGPoint(x: p.x + 80, y: p.y) : CGPoint(x: p.x, y: p.y + 60)
        }
        let d = ShakeDetector()
        XCTAssertTrue(Motion.feed(d, Motion.waypoints(pts, speed: 1500)).isEmpty)
    }

    func testHuntingBetweenButtonsWithPausesDoesNotFire() {
        // Fast moves between toolbar buttons, but a short stop on each.
        let pts = (0..<10).map { CGPoint(x: $0 % 2 == 0 ? 300 : 420, y: 40) }
        let d = ShakeDetector()
        XCTAssertTrue(Motion.feed(d, Motion.waypoints(pts, speed: 2000, dwell: 0.35)).isEmpty)
    }

    func testOvershootAndCorrectDoesNotFire() {
        let pts = [CGPoint(x: 100, y: 100), CGPoint(x: 900, y: 500), CGPoint(x: 860, y: 480), CGPoint(x: 880, y: 490), CGPoint(x: 870, y: 486)]
        let d = ShakeDetector()
        XCTAssertTrue(Motion.feed(d, Motion.waypoints(pts, speed: 3000)).isEmpty)
    }

    func testTinyJitterDoesNotFire() {
        // A resting hand on a trackpad: ±6 pt noise at high frequency.
        let d = ShakeDetector()
        XCTAssertTrue(Motion.feed(d, Motion.shake(amplitude: 6, hz: 8, duration: 4, jitter: 4, seed: 3)).isEmpty)
    }

    func testSmallFastShakeBelowSwingDoesNotFire() {
        // ±12 pt (24 pt strokes) — below minSwing.
        let d = ShakeDetector()
        XCTAssertTrue(Motion.feed(d, Motion.shake(amplitude: 12, hz: 5, duration: 2)).isEmpty)
    }

    // MARK: Warps, display jumps, pauses

    func testCursorWarpsBackAndForthDoNotFire() {
        // An app (or display rearrangement) teleporting the pointer between two spots.
        var path: Motion.Path = []
        for i in 0..<40 {
            let t = Double(i) * 0.03
            path.append((t, i % 2 == 0 ? 100 : 2400, 500))
        }
        let d = ShakeDetector()
        XCTAssertTrue(Motion.feed(d, path).isEmpty)
    }

    func testWarpMidShakeResetsCount() {
        let d = ShakeDetector()
        var path = Motion.shake(amplitude: 50, hz: 3, duration: 0.55)          // ~3 reversals
        let tWarp = path.last!.t + 0.008
        path.append((tWarp, 3000, 1200))                                         // warp
        path += Motion.shake(amplitude: 50, hz: 3, duration: 0.3, start: tWarp + 0.008, origin: CGPoint(x: 3000, y: 1200))
        XCTAssertTrue(Motion.feed(d, path).isEmpty)
    }

    func testCrossingDisplaysContinuouslyStillDetectsShake() {
        // Shaking across a display boundary at x = 1512 (global coordinates are continuous).
        let d = ShakeDetector()
        XCTAssertFalse(Motion.feed(d, Motion.shake(amplitude: 60, hz: 3, duration: 1.3, origin: CGPoint(x: 1512, y: 400))).isEmpty)
    }

    func testNegativeCoordinatesOnLeftDisplay() {
        let d = ShakeDetector()
        XCTAssertFalse(Motion.feed(d, Motion.shake(amplitude: 60, hz: 3, duration: 1.3, origin: CGPoint(x: -900, y: -200))).isEmpty)
    }

    func testPauseSplitsReversalsAcrossTheWindow() {
        // Two half-shakes separated by a pause are not one shake.
        let d = ShakeDetector()
        var path = Motion.shake(amplitude: 60, hz: 3, duration: 0.45)
        path += Motion.shake(amplitude: 60, hz: 3, duration: 0.45, start: path.last!.t + 0.6)
        XCTAssertTrue(Motion.feed(d, path).isEmpty)
    }

    func testTimestampGoingBackwardsResets() {
        let d = ShakeDetector()
        XCTAssertFalse(d.feed(x: 0, y: 0, at: 10))
        XCTAssertFalse(d.feed(x: 50, y: 0, at: 9))   // must not crash or count
        XCTAssertEqual(d.pendingReversals, 0)
    }

    func testResetClearsPartialShake() {
        let d = ShakeDetector()
        _ = Motion.feed(d, Motion.shake(amplitude: 60, hz: 3, duration: 0.55))
        d.reset()
        XCTAssertEqual(d.pendingReversals, 0)
        XCTAssertTrue(Motion.feed(d, Motion.shake(amplitude: 60, hz: 3, duration: 0.3, start: 0.6)).isEmpty)
    }

    func testRepeatedSamePointIsHarmless() {
        let d = ShakeDetector()
        for i in 0..<500 { XCTAssertFalse(d.feed(x: 10, y: 10, at: Double(i) * 0.008)) }
    }

    // MARK: Two-stage gesture

    func testSingleShakeDiscardsTopOnly() {
        let g = ShakeGesture()
        var results: [ShakeGesture.Result] = []
        for s in Motion.shake(amplitude: 60, hz: 3, duration: 1.0) {
            let r = g.feed(x: s.x, y: s.y, at: s.t)
            if r != .none { results.append(r) }
        }
        XCTAssertEqual(results, [.discardTop])
    }

    func testShakingOnPastFirstDiscardDiscardsAll() {
        let g = ShakeGesture()
        var results: [ShakeGesture.Result] = []
        for s in Motion.shake(amplitude: 60, hz: 3.5, duration: 2.6) {
            let r = g.feed(x: s.x, y: s.y, at: s.t)
            if r != .none { results.append(r) }
        }
        XCTAssertEqual(results.first, .discardTop)
        XCTAssertTrue(results.contains(.discardAll), "\(results)")
    }

    func testDiscardAllNotListenedForWithoutAFirstDiscard() {
        let g = ShakeGesture()
        // Feed the long detector's worth of slow reversals: never a discardAll first.
        var first: ShakeGesture.Result?
        for s in Motion.shake(amplitude: 60, hz: 3.5, duration: 2.6) {
            let r = g.feed(x: s.x, y: s.y, at: s.t)
            if r != .none, first == nil { first = r }
        }
        XCTAssertEqual(first, .discardTop)
    }

    func testStopAfterFirstDiscardKeepsTheRest() {
        let g = ShakeGesture()
        var results: [ShakeGesture.Result] = []
        var path = Motion.shake(amplitude: 60, hz: 3, duration: 0.95)
        // Then ordinary movement.
        path += Motion.waypoints([CGPoint(x: 800, y: 500), CGPoint(x: 1000, y: 700), CGPoint(x: 400, y: 300)], speed: 900, start: path.last!.t + 0.01)
        for s in path {
            let r = g.feed(x: s.x, y: s.y, at: s.t)
            if r != .none { results.append(r) }
        }
        XCTAssertEqual(results, [.discardTop])
    }
}
