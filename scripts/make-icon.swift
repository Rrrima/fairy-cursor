import AppKit
import CoreGraphics

let S: CGFloat = 1024
func render(_ path: String, markOnly: Bool) {
    let cs = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1) // top-left origin
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
    func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }

    // macOS icon grid: 824pt squircle inset 100
    let inset: CGFloat = 100, side = S - inset * 2
    let tile = CGRect(x: inset, y: inset, width: side, height: side)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)

    if !markOnly {
    // tile shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: c(0, 0, 0, 0.16))
    ctx.addPath(tilePath); ctx.setFillColor(c(0.96, 0.965, 0.975)); ctx.fillPath()
    ctx.restoreGState()

    // tile background: soft cool white, very subtle vertical gradient
    ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(grad([c(0.995, 0.996, 1.0), c(0.90, 0.915, 0.94)], [0, 1]), start: CGPoint(x: S/2, y: inset), end: CGPoint(x: S/2, y: S - inset), options: [])
    // faint ambient glow behind the mark
    ctx.drawRadialGradient(grad([c(0.70, 0.79, 0.96, 0.30), c(0.70, 0.79, 0.96, 0)], [0, 1]), startCenter: CGPoint(x: S/2, y: S/2), startRadius: 0, endCenter: CGPoint(x: S/2, y: S/2), endRadius: 330, options: [])
    ctx.restoreGState()
    // tile rim
    ctx.saveGState(); ctx.addPath(tilePath); ctx.setStrokeColor(c(1, 1, 1, 0.9)); ctx.setLineWidth(3); ctx.strokePath(); ctx.restoreGState()

    }

    // the mark (LogoMark.swift): ink, lit along its top edges, resting on a soft slate shadow.
    // `light` is for dark backgrounds (the readme on github's dark theme): a soft white mark.
    let light = CommandLine.arguments.contains("--light")
    let box: CGFloat = markOnly ? 900 : 500
    let mark = LogoMark.path(fitting: CGRect(x: (S - box) / 2, y: (S - box) / 2, width: box, height: box))
    let markBounds = mark.boundingBoxOfPath

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: box * 0.028), blur: box * 0.06, color: c(0.11, 0.15, 0.23, 0.28))
    ctx.addPath(mark); ctx.setFillColor(light ? c(0.90, 0.92, 0.95) : c(0.17, 0.20, 0.27)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState(); ctx.addPath(mark); ctx.clip()
    ctx.drawLinearGradient(grad(light ? [c(1, 1, 1), c(0.86, 0.89, 0.94)] : [c(0.27, 0.32, 0.42), c(0.15, 0.18, 0.25)], [0, 1]),
                           start: CGPoint(x: markBounds.midX, y: markBounds.minY), end: CGPoint(x: markBounds.midX, y: markBounds.maxY), options: [])
    // top-edge highlight: the mark minus itself nudged down leaves a thin lit rim
    var nudge = CGAffineTransform(translationX: 0, y: box * 0.009)
    let lower = mark.copy(using: &nudge)!
    // (cut out with a clear fill, not even-odd, which would light the stroke's own overlaps)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(c(1, 1, 1, 0.32)); ctx.fill(markBounds.insetBy(dx: -4, dy: -4))
    ctx.setBlendMode(.clear); ctx.addPath(lower); ctx.fillPath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
render(CommandLine.arguments[1], markOnly: CommandLine.arguments.contains("--mark-only"))
