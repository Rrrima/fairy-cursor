import Foundation

/// How the held pile travels after the cursor.
public enum FollowStyle: String, CaseIterable, Sendable {
    /// Stays right by the cursor.
    case close
    /// Glides after it and settles without a wobble. The default.
    case calm
    /// Hangs from it on a spring: arrives a little late, swings past, and leans into the move,
    /// like the demo on the website.
    case lively
}

/// The pile's position (and lean) from one frame to the next, as it chases a target.
///
/// `close` and `calm` ease straight to the target and never pass it. `lively` is a spring that's
/// a little underdamped, so every stop has one small swing past and back, and the pile tilts with
/// its sideways speed. Units are points, seconds and degrees.
public struct FollowMotion {
    public var style: FollowStyle

    public private(set) var x: Double = 0
    public private(set) var y: Double = 0
    /// Degrees to tilt the pile, positive clockwise. Always 0 unless `lively`.
    public private(set) var lean: Double = 0

    private var vx: Double = 0
    private var vy: Double = 0
    private var leanSpeed: Double = 0

    /// How fast the easing styles close the distance (1/s).
    static let closeRate: Double = 42
    static let calmRate: Double = 16
    /// The lively spring: stiffness and damping for the position (ζ ≈ 0.72) and for the lean.
    static let stiffness: Double = 95
    static let damping: Double = 14
    static let leanStiffness: Double = 110
    static let leanDamping: Double = 13
    /// Degrees of lean per point-per-second of sideways speed, and the most it leans.
    static let leanPerSpeed: Double = 0.014
    static let leanLimit: Double = 11
    /// Springs are stepped in slices this small so they stay stable at any frame rate.
    static let slice: Double = 1.0 / 240

    public init(style: FollowStyle = .calm) {
        self.style = style
    }

    /// Put the pile here, at rest (the first frame, or a jump that shouldn't be animated).
    public mutating func jump(toX x: Double, y: Double) {
        self.x = x
        self.y = y
        vx = 0; vy = 0; lean = 0; leanSpeed = 0
    }

    /// Move for `dt` seconds toward the target.
    public mutating func step(towardX tx: Double, y ty: Double, dt: Double) {
        guard dt > 0 else { return }
        switch style {
        case .close, .calm:
            let alpha = 1 - exp(-dt * (style == .close ? Self.closeRate : Self.calmRate))
            x += (tx - x) * alpha
            y += (ty - y) * alpha
            vx = 0; vy = 0
            // Coming from lively: straighten up rather than freeze mid-lean.
            lean += (0 - lean) * alpha
            leanSpeed = 0
        case .lively:
            var left = dt
            while left > 0 {
                let h = min(left, Self.slice)
                left -= h
                vx += (-Self.stiffness * (x - tx) - Self.damping * vx) * h
                vy += (-Self.stiffness * (y - ty) - Self.damping * vy) * h
                x += vx * h
                y += vy * h
                let wanted = max(-Self.leanLimit, min(Self.leanLimit, vx * Self.leanPerSpeed))
                leanSpeed += (-Self.leanStiffness * (lean - wanted) - Self.leanDamping * leanSpeed) * h
                lean += leanSpeed * h
            }
        }
    }
}
