import CoreGraphics
import Foundation

/// The part of the display a screen recording shows: the output video is this area scaled to the
/// full frame, so a smaller area reads as zooming in.
///
/// ⌥ + scroll sets a target zoom; the actual zoom eases toward it, so a flick of the wheel becomes
/// one smooth push in rather than a jump. The area follows the cursor lazily: it only moves when
/// the cursor gets near its edge, so small movements don't make the video swim.
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
    /// How quickly the area slides to keep the cursor in view (per second).
    public var followResponse: Double = 7
    /// While the cursor stays this far inside the area (fraction of its size), the area holds still.
    public var followMargin: CGFloat = 0.2

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

    /// Advance by `dt` seconds with the cursor at `cursor`.
    public mutating func step(cursor: CGPoint, dt: Double) {
        let dt = max(0, min(dt, 0.25))
        zoom = approach(zoom, targetZoom, response: zoomResponse, dt: dt)
        if abs(zoom - targetZoom) < 0.0005 { zoom = targetZoom }

        // Where the area would need to sit to keep the cursor inside its calm middle.
        let size = areaSize(zoom: zoom)
        let current = area(zoom: zoom, center: targetCenter)
        let inset = current.insetBy(dx: size.width * followMargin, dy: size.height * followMargin)
        var want = targetCenter
        if cursor.x < inset.minX { want.x -= inset.minX - cursor.x }
        if cursor.x > inset.maxX { want.x += cursor.x - inset.maxX }
        if cursor.y < inset.minY { want.y -= inset.minY - cursor.y }
        if cursor.y > inset.maxY { want.y += cursor.y - inset.maxY }
        targetCenter = clampedCenter(want, size: size)

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
