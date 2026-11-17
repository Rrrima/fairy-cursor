import CoreGraphics
import Foundation

/// Hand-drawn strokes that feel like ink: a Swift port of Steve Ruiz's perfect-freehand
/// (MIT, https://github.com/steveruiz/perfect-freehand), the algorithm Excalidraw draws with.
///
/// Instead of a line of fixed width, a stroke is a filled outline whose width follows a
/// simulated pen pressure: fast movement thins the line, slow movement fills it out. The input
/// is "streamlined" (each point eases toward the pointer), which irons out hand jitter.
///
/// Coordinates are y-down, like the original.
public enum Freehand {
    public struct Options: Sendable {
        /// Diameter of the stroke at full pressure.
        public var size: CGFloat
        /// How much pressure changes the width: 0 = even width, 1 = very thin when fast.
        public var thinning: CGFloat
        /// Softens the outline's edges (0…1).
        public var smoothing: CGFloat
        /// How far each point eases toward the pointer (0…1); higher = smoother, laggier.
        public var streamline: CGFloat
        /// Maps pressure to width.
        public var easing: @Sendable (CGFloat) -> CGFloat

        public init(size: CGFloat, thinning: CGFloat = 0.5, smoothing: CGFloat = 0.5, streamline: CGFloat = 0.5,
                    easing: @escaping @Sendable (CGFloat) -> CGFloat = { $0 }) {
            self.size = size
            self.thinning = thinning
            self.smoothing = smoothing
            self.streamline = streamline
            self.easing = easing
        }
    }

    struct StrokePoint {
        var point: CGPoint
        var pressure: CGFloat
        var vector: CGPoint
        var distance: CGFloat
        var runningLength: CGFloat
    }

    private static let ratePressureChange: CGFloat = 0.275
    private static let fixedPi = CGFloat.pi + 0.0001

    /// The outline polygon of a stroke through `points`. `complete`: the pen has lifted, so the
    /// stroke runs all the way to the last point instead of trailing behind it.
    public static func outline(_ points: [CGPoint], _ options: Options, complete: Bool) -> [CGPoint] {
        outlinePoints(strokePoints(points, options, complete: complete), options, complete: complete)
    }

    /// A smooth closed path through the outline: quadratic curves through the midpoints.
    public static func path(_ outline: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard outline.count > 2 else { return path }
        path.move(to: outline[0])
        for i in 0..<outline.count {
            let a = outline[i], b = outline[(i + 1) % outline.count]
            path.addQuadCurve(to: mid(a, b), control: a)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Points along the stroke

    static func strokePoints(_ input: [CGPoint], _ options: Options, complete: Bool) -> [StrokePoint] {
        guard !input.isEmpty else { return [] }
        let t = 0.15 + (1 - options.streamline) * 0.85
        var pts = input
        if pts.count == 2 {
            // Two points make a straight line: add a few in between so it has a body.
            let last = pts[1]
            pts = [pts[0]] + (1...4).map { lerp(pts[0], last, CGFloat($0) / 4) }
        } else if pts.count == 1 {
            pts.append(add(pts[0], CGPoint(x: 1, y: 1)))
        }

        var result = [StrokePoint(point: pts[0], pressure: 0.25, vector: CGPoint(x: 1, y: 1), distance: 0, runningLength: 0)]
        var reachedMinimumLength = false
        var runningLength: CGFloat = 0
        var prev = result[0]
        let max = pts.count - 1
        for i in 1..<pts.count {
            let point = complete && i == max ? pts[i] : lerp(prev.point, pts[i], t)
            if point == prev.point { continue }
            let distance = dist(point, prev.point)
            runningLength += distance
            if i < max && !reachedMinimumLength {
                if runningLength < options.size { continue }
                reachedMinimumLength = true
            }
            prev = StrokePoint(point: point, pressure: 0.5, vector: unit(sub(prev.point, point)),
                               distance: distance, runningLength: runningLength)
            result.append(prev)
        }
        result[0].vector = result.count > 1 ? result[1].vector : .zero
        return result
    }

    // MARK: - Outline

    static func outlinePoints(_ points: [StrokePoint], _ options: Options, complete: Bool) -> [CGPoint] {
        let size = options.size
        guard let lastStroke = points.last, size > 0 else { return [] }
        let totalLength = lastStroke.runningLength
        let minDistance = pow(size * options.smoothing, 2)
        var left: [CGPoint] = [], right: [CGPoint] = []

        // Start from the pressure the first few points suggest, so the line doesn't begin blobby.
        var prevPressure = points.prefix(10).reduce(points[0].pressure) { acc, current in
            let sp = min(1, current.distance / size)
            let rp = min(1, 1 - sp)
            let pressure = min(1, acc + (rp - acc) * (sp * ratePressureChange))
            return (acc + pressure) / 2
        }
        var radius = strokeRadius(size, options.thinning, lastStroke.pressure, options.easing)
        var firstRadius: CGFloat?
        var prevVector = points[0].vector
        var pl = points[0].point, pr = pl
        var tl = pl, tr = pr
        var prevSharp = false

        for i in 0..<points.count {
            let current = points[i]
            let point = current.point, vector = current.vector
            if i < points.count - 1 && totalLength - current.runningLength < 3 { continue }

            var pressure = current.pressure
            if options.thinning != 0 {
                let sp = min(1, current.distance / size)
                let rp = min(1, 1 - sp)
                pressure = min(1, prevPressure + (rp - prevPressure) * (sp * ratePressureChange))
                radius = strokeRadius(size, options.thinning, pressure, options.easing)
            } else {
                radius = size / 2
            }
            if firstRadius == nil { firstRadius = radius }
            radius = Swift.max(0.01, radius)

            let nextVector = (i < points.count - 1 ? points[i + 1] : points[i]).vector
            let nextDot = i < points.count - 1 ? dot(vector, nextVector) : 1
            let prevDot = dot(vector, prevVector)
            let sharp = prevDot < 0 && !prevSharp
            let nextSharp = nextDot < 0

            if sharp || nextSharp {
                // A hairpin: round the corner instead of letting the outline cross itself.
                let offset = mul(perp(prevVector), radius)
                var t: CGFloat = 0
                while t <= 1 {
                    tl = rotate(sub(point, offset), around: point, by: fixedPi * t)
                    left.append(tl)
                    tr = rotate(add(point, offset), around: point, by: fixedPi * -t)
                    right.append(tr)
                    t += 1 / 13
                }
                pl = tl
                pr = tr
                if nextSharp { prevSharp = true }
                continue
            }
            prevSharp = false

            if i == points.count - 1 {
                let offset = mul(perp(vector), radius)
                left.append(sub(point, offset))
                right.append(add(point, offset))
                continue
            }

            let offset = mul(perp(lerp(nextVector, vector, nextDot)), radius)
            tl = sub(point, offset)
            if i <= 1 || dist2(pl, tl) > minDistance {
                left.append(tl)
                pl = tl
            }
            tr = add(point, offset)
            if i <= 1 || dist2(pr, tr) > minDistance {
                right.append(tr)
                pr = tr
            }
            prevPressure = pressure
            prevVector = vector
        }

        let firstPoint = points[0].point
        let lastPoint = points.count > 1 ? lastStroke.point : add(points[0].point, CGPoint(x: 1, y: 1))

        if points.count == 1 {
            // A click: a round dot.
            let start = project(firstPoint, unit(perp(sub(firstPoint, lastPoint))), -(firstRadius ?? radius))
            var dot: [CGPoint] = []
            var t: CGFloat = 1 / 13
            while t <= 1 {
                dot.append(rotate(start, around: firstPoint, by: fixedPi * 2 * t))
                t += 1 / 13
            }
            return dot
        }

        var startCap: [CGPoint] = []
        if let first = right.first {
            var t: CGFloat = 1 / 13
            while t <= 1 {
                startCap.append(rotate(first, around: firstPoint, by: fixedPi * t))
                t += 1 / 13
            }
        }
        var endCap: [CGPoint] = []
        let direction = perp(neg(lastStroke.vector))
        let start = project(lastPoint, direction, radius)
        var t: CGFloat = 1 / 29
        while t < 1 {
            endCap.append(rotate(start, around: lastPoint, by: fixedPi * 3 * t))
            t += 1 / 29
        }
        return left + endCap + right.reversed() + startCap
    }

    private static func strokeRadius(_ size: CGFloat, _ thinning: CGFloat, _ pressure: CGFloat,
                                      _ easing: (CGFloat) -> CGFloat) -> CGFloat {
        size * easing(0.5 - thinning * (0.5 - pressure))
    }

    // MARK: - Vectors

    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    private static func sub(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    private static func mul(_ a: CGPoint, _ n: CGFloat) -> CGPoint { CGPoint(x: a.x * n, y: a.y * n) }
    private static func neg(_ a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: -a.y) }
    private static func perp(_ a: CGPoint) -> CGPoint { CGPoint(x: a.y, y: -a.x) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }
    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { add(a, mul(sub(b, a), t)) }
    private static func project(_ a: CGPoint, _ b: CGPoint, _ c: CGFloat) -> CGPoint { add(a, mul(b, c)) }
    private static func dist2(_ a: CGPoint, _ b: CGPoint) -> CGFloat { pow(a.x - b.x, 2) + pow(a.y - b.y, 2) }
    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func unit(_ a: CGPoint) -> CGPoint {
        let length = hypot(a.x, a.y)
        return length == 0 ? a : CGPoint(x: a.x / length, y: a.y / length)
    }

    private static func rotate(_ a: CGPoint, around c: CGPoint, by r: CGFloat) -> CGPoint {
        let s = sin(r), co = cos(r)
        let px = a.x - c.x, py = a.y - c.y
        return CGPoint(x: px * co - py * s + c.x, y: px * s + py * co + c.y)
    }
}
