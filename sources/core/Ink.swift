import CoreGraphics

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
    static let minStep: CGFloat = 1.5

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

    /// A smooth line through the points: straight segments become quadratic curves through
    /// their midpoints, so a quick hand-drawn line doesn't look like a polygon. One point
    /// draws a dot (a zero-length line with a round cap).
    public static func path(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
