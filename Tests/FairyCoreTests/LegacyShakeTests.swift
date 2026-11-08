import CoreGraphics
import Foundation
import XCTest
@testable import FairyCore

/// The detector Fairy Cursor shipped with (verbatim logic): reversals counted per axis, 18 pt
/// swing, 4 reversals in 1 s. Kept here to document which ordinary movements it mistook for a
/// shake — each of these silently discarded a carried screenshot.
private final class LegacyShakeDetector {
    struct Sample { let t: TimeInterval; let x: CGFloat; let y: CGFloat }
    var requiredReversals = 4, window: TimeInterval = 1.0, minSwing: CGFloat = 18, cooldown: TimeInterval = 1.0
    private var samples: [Sample] = []
    private var lastFired: TimeInterval = 0
    func feed(x: CGFloat, y: CGFloat, at t: TimeInterval) -> Bool {
        samples.append(Sample(t: t, x: x, y: y))
        let cutoff = t - window
        if let first = samples.firstIndex(where: { $0.t >= cutoff }), first > 0 { samples.removeFirst(first) }
        guard t - lastFired > cooldown, samples.count >= 4 else { return false }
        if max(reversals(samples.map { $0.x }), reversals(samples.map { $0.y })) >= requiredReversals {
            lastFired = t; samples.removeAll(); return true
        }
        return false
    }
    private func reversals(_ values: [CGFloat]) -> Int {
        var count = 0, direction = 0
        var turning = values[0]
        for v in values.dropFirst() {
            let d = v - turning
            if direction == 0 { if abs(d) >= minSwing { direction = d > 0 ? 1 : -1; turning = v } }
            else if (d > 0) == (direction > 0) { turning = v }
            else if abs(d) >= minSwing { count += 1; direction = -direction; turning = v }
        }
        return count
    }
}

final class LegacyShakeTests: XCTestCase {
    private func legacyFires(_ path: Motion.Path) -> Bool {
        let d = LegacyShakeDetector()
        return path.contains { d.feed(x: $0.x, y: $0.y, at: $0.t + 100) }
    }
    private func newFires(_ path: Motion.Path) -> Bool {
        let d = ShakeDetector()
        return path.contains { d.feed(x: $0.x, y: $0.y, at: $0.t + 100) }
    }

    func testCirclingWasAFalseShake() {
        let path = Motion.circle(radius: 40, hz: 2, duration: 1.5)
        XCTAssertTrue(legacyFires(path), "legacy detector discarded on circling")
        XCTAssertFalse(newFires(path))
    }

    func testSlowishComparingWasAFalseShake() {
        // Glancing between two things 60 pt apart at ~2.2 Hz.
        let path = Motion.shake(amplitude: 30, hz: 2.2, duration: 1.5)
        XCTAssertTrue(legacyFires(path))
        // 60 pt strokes at 2.2 Hz is ~260 pt/s — still a "shake" by the new speed rule only if it
        // reverses 4 times within 1 s, which 2.2 Hz does not quite reach in a straight line.
        XCTAssertFalse(newFires(Motion.shake(amplitude: 30, hz: 1.6, duration: 2)))
    }

    func testSmallCirclesAroundAnItemWereAFalseShake() {
        // Circling a word while talking someone through the screen.
        let path = Motion.circle(radius: 30, hz: 2.5, duration: 1.2)
        XCTAssertTrue(legacyFires(path))
        XCTAssertFalse(newFires(path))
    }

    func testDiagonalDriftWithVerticalJitterWasAFalseShake() {
        // Moving steadily right while the hand bobs ±12 pt vertically (trackpad thumb drag):
        // the legacy y-axis counter saw reversals every bob.
        var path: Motion.Path = []
        for i in 0...150 {
            let t = Double(i) / 120
            path.append((t, 200 + CGFloat(t) * 600, 400 + 12 * CGFloat(sin(2 * .pi * 3 * t))))
        }
        XCTAssertTrue(legacyFires(path))
        XCTAssertFalse(newFires(path))
    }

    func testWarpsWereAFalseShake() {
        var path: Motion.Path = []
        for i in 0..<12 { path.append((Double(i) * 0.06, i % 2 == 0 ? 100 : 1900, 500)) }
        XCTAssertTrue(legacyFires(path))
        XCTAssertFalse(newFires(path))
    }
}
