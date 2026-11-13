import CoreGraphics

/// The fairy cursor mark: a cursor arrow drawn as one thick, open, rounded stroke whose tail
/// curls back in, with two eyes inside. One source for the menu bar glyph (here) and the app and
/// readme icons (`scripts/make-icon.swift` compiles against this file).
///
/// Geometry lives in a 1254-pt design space with y pointing down; `path(fitting:)` scales it.
enum LogoMark {
    static let strokeWidth: CGFloat = 96

    /// The stroke's centerline: from the inner end of the bottom hook, down and around, up the
    /// left side, over the top corner, along the diagonal to the tip, then curling back in.
    static func centerline() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 618, y: 842))
        p.addCurve(to: CGPoint(x: 479, y: 963), control1: CGPoint(x: 570, y: 902), control2: CGPoint(x: 535, y: 968))
        p.addCurve(to: CGPoint(x: 419, y: 520), control1: CGPoint(x: 420, y: 955), control2: CGPoint(x: 404, y: 640))
        p.addCurve(to: CGPoint(x: 545, y: 460), control1: CGPoint(x: 428, y: 455), control2: CGPoint(x: 480, y: 432))
        p.addCurve(to: CGPoint(x: 864, y: 659), control1: CGPoint(x: 660, y: 512), control2: CGPoint(x: 792, y: 598))
        p.addCurve(to: CGPoint(x: 774, y: 773), control1: CGPoint(x: 922, y: 710), control2: CGPoint(x: 880, y: 768))
        return p
    }

    /// Two upright ovals, leaning a touch toward the tip.
    static func eyes() -> CGPath {
        let p = CGMutablePath()
        for center in [CGPoint(x: 568, y: 683), CGPoint(x: 652, y: 658)] {
            let t = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -0.12)
            p.addEllipse(in: CGRect(x: -24, y: -40, width: 48, height: 80), transform: t)
        }
        return p
    }

    /// The whole mark as one fillable outline (stroke + eyes), in design space.
    static func outline() -> CGPath {
        let p = CGMutablePath()
        p.addPath(centerline().copy(strokingWithWidth: strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10))
        p.addPath(eyes())
        return p
    }

    /// The mark scaled to fit `rect`, centred. `yUp` flips it for bottom-left-origin contexts.
    static func path(fitting rect: CGRect, yUp: Bool = false) -> CGPath {
        let shape = outline()
        let box = shape.boundingBoxOfPath
        let scale = min(rect.width / box.width, rect.height / box.height)
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        t = t.scaledBy(x: scale, y: yUp ? -scale : scale)
        t = t.translatedBy(x: -box.midX, y: -box.midY)
        return shape.copy(using: &t) ?? shape
    }
}
