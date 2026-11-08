import CoreGraphics
import Foundation

/// Detects a deliberate "shake" — fast back-and-forth strokes along one line — from a stream of
/// cursor positions (global points). Any direction works (horizontal, vertical, diagonal).
///
/// A shake discards a screenshot, so this is deliberately strict about what counts:
///  - a stroke must travel at least `minSwing` points and move at `minStrokeSpeed` or faster;
///  - a reversal is a turn of at least ~145° (`reversalCosine`): circling, zig-zagging along a
///    staircase or wandering between targets turn by ~90° and never count;
///  - `requiredReversals` reversals must fall within `window` seconds;
///  - a pause longer than `maxPause` or a cursor warp (a jump larger than `maxJump` between two
///    consecutive samples, e.g. an app warping the pointer or a display reconfiguration) starts
///    over.
///
/// Not thread-safe; feed it from one thread.
public final class ShakeDetector {
    public var requiredReversals = 4
    public var window: TimeInterval = 1.0
    /// Minimum stroke length (points). 30 pt is still an easy trackpad wiggle.
    public var minSwing: CGFloat = 30
    /// Minimum average speed of the stroke that ends in a reversal (points/second).
    public var minStrokeSpeed: CGFloat = 220
    /// cos of the smallest turn that counts as a reversal (-0.82 ≈ 145°).
    public var reversalCosine: CGFloat = -0.82
    public var maxPause: TimeInterval = 0.3
    public var maxJump: CGFloat = 500
    public var cooldown: TimeInterval = 1.0

    private struct Point {
        var p: CGPoint
        var t: TimeInterval
    }

    private var last: Point?
    private var anchor: Point?          // where the current stroke started (last turning point)
    private var extreme: Point?         // farthest point reached along the current stroke
    private var direction: CGVector?    // unit direction of the current stroke
    private var reversals: [TimeInterval] = []
    private var lastFired: TimeInterval = -.infinity

    public init() {}

    /// Forget the current motion (keeps the cooldown).
    public func reset() {
        last = nil
        anchor = nil
        extreme = nil
        direction = nil
        reversals.removeAll()
    }

    /// Number of reversals currently counted inside the window (for diagnostics/tests).
    public var pendingReversals: Int { reversals.count }

    /// Feed a cursor position; returns true once per detected shake.
    public func feed(x: CGFloat, y: CGFloat, at t: TimeInterval) -> Bool {
        let sample = Point(p: CGPoint(x: x, y: y), t: t)
        if let previous = last {
            let gap = t - previous.t
            if gap < 0 || gap > maxPause || distance(previous.p, sample.p) > maxJump {
                reset()
            }
        }
        last = sample

        guard let start = anchor else {
            anchor = sample
            return false
        }
        guard let dir = direction, let far = extreme else {
            // No stroke yet. A wiggle can start anywhere, so measure from the starting point and
            // from the farthest point reached so far (a small shake centred on the first sample
            // never gets `minSwing` away from it).
            let fromStart = vector(start.p, sample.p)
            if let provisional = extreme, length(vector(provisional.p, sample.p)) >= minSwing,
               length(vector(provisional.p, sample.p)) > length(fromStart) {
                anchor = provisional
                direction = unit(vector(provisional.p, sample.p))
                extreme = sample
            } else if length(fromStart) >= minSwing {
                direction = unit(fromStart)
                extreme = sample
            } else if extreme == nil || length(fromStart) > length(vector(start.p, extreme!.p)) {
                extreme = sample          // provisional: farthest point from the start so far
            }
            return false
        }

        let reached = dot(vector(start.p, far.p), dir)
        let now = dot(vector(start.p, sample.p), dir)
        if now >= reached {
            extreme = sample               // still travelling the same way
            return false
        }
        let back = vector(far.p, sample.p)
        let backLength = length(back)
        guard backLength >= minSwing else { return false }

        let cosine = dot(back, dir) / backLength
        let strokeLength = length(vector(start.p, far.p))
        let strokeTime = max(far.t - start.t, 0.001)
        let fastEnough = strokeLength / CGFloat(strokeTime) >= minStrokeSpeed
        if cosine <= reversalCosine && fastEnough {
            reversals.append(t)
        } else if cosine > reversalCosine {
            // A sideways turn (circle, staircase): not a shake; start counting again.
            reversals.removeAll()
        }
        anchor = far
        direction = unit(back)
        extreme = sample

        reversals.removeAll { t - $0 > window }
        guard t - lastFired > cooldown, reversals.count >= requiredReversals else { return false }
        lastFired = t
        reset()
        return true
    }

    // MARK: - Vector helpers

    private func vector(_ a: CGPoint, _ b: CGPoint) -> CGVector { CGVector(dx: b.x - a.x, dy: b.y - a.y) }
    private func length(_ v: CGVector) -> CGFloat { (v.dx * v.dx + v.dy * v.dy).squareRoot() }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { length(vector(a, b)) }
    private func dot(_ a: CGVector, _ b: CGVector) -> CGFloat { a.dx * b.dx + a.dy * b.dy }
    private func unit(_ v: CGVector) -> CGVector {
        let l = length(v)
        return l > 0 ? CGVector(dx: v.dx / l, dy: v.dy / l) : CGVector(dx: 1, dy: 0)
    }
}

/// The two-stage shake: a shake discards the top screenshot; shaking on past it (within
/// `armDuration`) discards the rest of the pile. The second stage is only listened for right
/// after a first discard, so one enthusiastic shake can't silently empty a whole pile.
public final class ShakeGesture {
    public enum Result: Equatable { case none, discardTop, discardAll }

    public let single = ShakeDetector()
    public let long: ShakeDetector = {
        let d = ShakeDetector()
        d.requiredReversals = 4
        d.window = 1.4
        d.cooldown = 1.5
        return d
    }()
    /// How long after a first discard further shaking counts towards "discard all".
    public var armDuration: TimeInterval = 1.6
    private var armedUntil: TimeInterval = -.infinity

    public init() {}

    public func reset() {
        single.reset()
        long.reset()
        armedUntil = -.infinity
    }

    public func feed(x: CGFloat, y: CGFloat, at t: TimeInterval) -> Result {
        if t <= armedUntil {
            if long.feed(x: x, y: y, at: t) {
                armedUntil = -.infinity
                single.reset()
                return .discardAll
            }
        }
        if single.feed(x: x, y: y, at: t) {
            long.reset()
            armedUntil = t + armDuration
            return .discardTop
        }
        return .none
    }
}

/// Feeds cursor movement to the shake gesture only when a shake can mean "discard": something
/// is held and the system screenshot UI is not up. While the user aims the ⌘⇧4 crosshair or
/// sweeps across windows in window-pick mode, the pile is invisible — that movement used to
/// count, and quietly shook screenshots off.
public final class ShakeGate {
    public let gesture = ShakeGesture()
    public private(set) var captureUIVisible = false

    public init() {}

    public func screenshotUIShown() {
        captureUIVisible = true
        gesture.reset()
    }

    public func screenshotUIGone() {
        captureUIVisible = false
        gesture.reset()
    }

    /// A new capture landed on the pile: start from a clean slate.
    public func captured() { gesture.reset() }

    public func move(x: CGFloat, y: CGFloat, at t: TimeInterval, holding: Bool) -> ShakeGesture.Result {
        guard holding, !captureUIVisible else { return .none }
        return gesture.feed(x: x, y: y, at: t)
    }
}
