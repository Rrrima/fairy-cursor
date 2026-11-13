import CoreGraphics
import Foundation

/// The part of the display a screen recording shows: the output video is this area scaled to the
/// full frame, so a smaller area reads as zooming in.
///
/// ⌥ + scroll sets a target zoom; the actual zoom eases toward it, so a flick of the wheel becomes
/// one smooth push in rather than a jump. The area moves only while ⌥ is held: then it glides to
/// centre on the cursor. Let go of ⌥ and it stays where it is, wherever the cursor wanders.
///
/// Geometry is in global points with a top-left origin (CoreGraphics / CGEvent space), the same
/// space as `display`. Pure and value-typed; the recorder steps it once per output frame.
public struct RecordingViewport {
    /// The recorded display, in global points.
    public let display: CGRect
    public var minZoom: CGFloat = 1
    public var maxZoom: CGFloat = 4
    /// How quickly the zoom catches up with its target (per second; higher is snappier).
    public var zoomResponse: Double = 9
    /// How quickly the area glides to the cursor while following (per second).
    public var followResponse: Double = 7

    public private(set) var targetZoom: CGFloat = 1
    public private(set) var zoom: CGFloat = 1
    public private(set) var center: CGPoint
    private var targetCenter: CGPoint

    public init(display: CGRect) {
        self.display = display
        center = CGPoint(x: display.midX, y: display.midY)
        targetCenter = center
    }

    /// Change the target zoom by a factor of e^amount (positive zooms in).
    public mutating func zoom(by amount: CGFloat) {
        targetZoom = min(maxZoom, max(minZoom, targetZoom * exp(amount)))
    }

    /// The area shown right now.
    public var area: CGRect { area(zoom: zoom, center: center) }

    /// Advance by `dt` seconds with the cursor at `cursor`. `following` (⌥ held) lets the area
    /// move to the cursor; otherwise it stays put and only the zoom keeps easing.
    public mutating func step(cursor: CGPoint, following: Bool, dt: Double) {
        let dt = max(0, min(dt, 0.25))
        zoom = approach(zoom, targetZoom, response: zoomResponse, dt: dt)
        if abs(zoom - targetZoom) < 0.0005 { zoom = targetZoom }

        let size = areaSize(zoom: zoom)
        // Following: glide toward the cursor. Not following: stop right where it is (no drift
        // toward wherever the cursor was when ⌥ was let go).
        targetCenter = following ? cursor : center
        targetCenter = clampedCenter(targetCenter, size: size)
        center = CGPoint(x: approach(center.x, targetCenter.x, response: followResponse, dt: dt),
                         y: approach(center.y, targetCenter.y, response: followResponse, dt: dt))
        center = clampedCenter(center, size: size)
    }

    // MARK: - Geometry

    private func areaSize(zoom: CGFloat) -> CGSize {
        CGSize(width: display.width / zoom, height: display.height / zoom)
    }

    private func area(zoom: CGFloat, center: CGPoint) -> CGRect {
        let size = areaSize(zoom: zoom)
        let c = clampedCenter(center, size: size)
        return CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Keep an area of `size` around `point` entirely on the display.
    private func clampedCenter(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(point.x, display.minX + size.width / 2), display.maxX - size.width / 2),
                y: min(max(point.y, display.minY + size.height / 2), display.maxY - size.height / 2))
    }

    /// Exponential approach: frame-rate independent smoothing.
    private func approach(_ value: CGFloat, _ target: CGFloat, response: Double, dt: Double) -> CGFloat {
        value + (target - value) * CGFloat(1 - exp(-response * dt))
    }
}
