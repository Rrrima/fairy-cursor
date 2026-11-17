import CoreGraphics
import Foundation

/// What the cursor draws with while recording.
public enum InkTool: String, Sendable, CaseIterable {
    case pen, highlighter
}

/// The keys the ink answers to while recording.
public enum InkKey: Sendable {
    /// ⌘⇧7 / ⌘⇧8: take that tool, or put it down if it's already in hand.
    case pen, highlighter
    /// esc: back to the normal cursor.
    case done
    /// ⌘Z: take back the last stroke.
    case undo
    /// ⌫: wipe the screen, keep drawing.
    case clear
}

/// The ink on screen during a recording: which tool is in hand and the strokes drawn with it.
/// Pure; `InkOverlay` in the recording capability draws it and feeds it the mouse.
public struct Ink: Sendable {
    public struct Stroke: Sendable, Equatable {
        public let tool: InkTool
        public internal(set) var points: [CGPoint]
    }

    /// nil: the normal cursor (clicks go to the apps underneath).
    public private(set) var tool: InkTool?
    public private(set) var strokes: [Stroke] = []
    /// The stroke being drawn right now (mouse is down).
    public private(set) var current: Stroke?

    /// Points closer than this to the previous one add nothing but weight.
    static let minStep: CGFloat = 1

    public init() {}

    public var isDrawing: Bool { tool != nil }

    /// Returns whether the key did something; keys that didn't are left for the app underneath.
    @discardableResult
    public mutating func press(_ key: InkKey) -> Bool {
        switch key {
        case .pen, .highlighter:
            let wanted: InkTool = key == .pen ? .pen : .highlighter
            if tool == wanted { putDown() } else { endStroke(); tool = wanted }
            return true
        case .done:
            guard isDrawing else { return false }
            putDown()
            return true
        case .undo:
            guard isDrawing else { return false }
            if current != nil { current = nil } else if !strokes.isEmpty { strokes.removeLast() }
            return true
        case .clear:
            guard isDrawing else { return false }
            current = nil
            strokes.removeAll()
            return true
        }
    }

    public mutating func beginStroke(at point: CGPoint) {
        guard let tool = tool else { return }
        endStroke()
        current = Stroke(tool: tool, points: [point])
    }

    public mutating func extendStroke(to point: CGPoint) {
        guard var stroke = current, let last = stroke.points.last else { return }
        guard hypot(point.x - last.x, point.y - last.y) >= Self.minStep else { return }
        stroke.points.append(point)
        current = stroke
    }

    public mutating func endStroke() {
        guard let stroke = current else { return }
        strokes.append(stroke)
        current = nil
    }

    /// Back to the normal cursor. The ink goes with it: it was drawn for that moment.
    public mutating func putDown() {
        tool = nil
        current = nil
        strokes.removeAll()
    }

    /// How each tool's ink behaves (see `Freehand`).
    public static func options(for tool: InkTool) -> Freehand.Options {
        switch tool {
        case .pen:
            // Excalidraw's freedraw settings (its "bold" width): the line swells when you slow
            // down and thins when you flick, with a soft ease into full pressure.
            return Freehand.Options(size: 8.5, thinning: 0.6, smoothing: 0.5, streamline: 0.5,
                                    easing: { sin($0 * .pi / 2) })
        case .highlighter:
            // A marker keeps its width; it only gets the smoothing.
            return Freehand.Options(size: 22, thinning: 0, smoothing: 0.5, streamline: 0.6)
        }
    }

    /// The filled shape of a stroke. `complete`: the pen has lifted, so it reaches the last point.
    public static func shape(of stroke: Stroke, complete: Bool) -> CGPath {
        Freehand.path(Freehand.outline(stroke.points, options(for: stroke.tool), complete: complete))
    }
}
