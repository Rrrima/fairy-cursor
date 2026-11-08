import AppKit
import CoreGraphics

let S: CGFloat = 1024
func render(_ path: String) {
    let cs = CGColorSpace(name: CGColorSpace.displayP3)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1) // top-left origin
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
    func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }

    // macOS icon grid: 824pt squircle inset 100
    let inset: CGFloat = 100, side = S - inset * 2
    let tile = CGRect(x: inset, y: inset, width: side, height: side)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)

    // tile shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: c(0, 0, 0, 0.16))
    ctx.addPath(tilePath); ctx.setFillColor(c(0.96, 0.965, 0.975)); ctx.fillPath()
    ctx.restoreGState()

    // tile background: soft cool white, very subtle vertical gradient
    ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
    ctx.drawLinearGradient(grad([c(0.995, 0.996, 1.0), c(0.90, 0.915, 0.94)], [0, 1]), start: CGPoint(x: S/2, y: inset), end: CGPoint(x: S/2, y: S - inset), options: [])
    // faint ambient glow behind the bead
    ctx.drawRadialGradient(grad([c(0.70, 0.79, 0.96, 0.30), c(0.70, 0.79, 0.96, 0)], [0, 1]), startCenter: CGPoint(x: S/2, y: S/2), startRadius: 0, endCenter: CGPoint(x: S/2, y: S/2), endRadius: 330, options: [])
    ctx.restoreGState()
    // tile rim
    ctx.saveGState(); ctx.addPath(tilePath); ctx.setStrokeColor(c(1, 1, 1, 0.9)); ctx.setLineWidth(3); ctx.strokePath(); ctx.restoreGState()

    // bead
    let r: CGFloat = 178
    let ctr = CGPoint(x: S/2, y: S/2 - 6)
    let bead = CGRect(x: ctr.x - r, y: ctr.y - r, width: r * 2, height: r * 2)

    // soft contact shadow, clipped to the tile
    ctx.saveGState(); ctx.addPath(tilePath); ctx.clip()
    ctx.translateBy(x: ctr.x, y: ctr.y + r * 0.92); ctx.scaleBy(x: 1, y: 0.32)
    ctx.drawRadialGradient(grad([c(0.20, 0.26, 0.42, 0.20), c(0.20, 0.26, 0.42, 0)], [0, 1]), startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r * 1.05, options: [])
    ctx.restoreGState()

    ctx.saveGState(); ctx.addEllipse(in: bead); ctx.clip()
    // mostly clear: a faint cool tint over the tile
    ctx.setFillColor(c(0.84, 0.88, 0.97, 0.46)); ctx.fill(bead)
    // light pooling at the bottom (refraction)
    ctx.drawRadialGradient(grad([c(1, 1, 1, 0.85), c(1, 1, 1, 0)], [0, 1]), startCenter: CGPoint(x: ctr.x, y: ctr.y + r * 0.78), startRadius: 0, endCenter: CGPoint(x: ctr.x, y: ctr.y + r * 0.55), endRadius: r * 0.78, options: [])
    // thin refractive edge
    ctx.drawRadialGradient(grad([c(0.42, 0.50, 0.68, 0), c(0.42, 0.50, 0.68, 0), c(0.38, 0.46, 0.66, 0.44)], [0, 0.82, 1]), startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: r, options: [])
    ctx.restoreGState()

    // specular: a thin crescent hugging the top-left rim
    ctx.saveGState(); ctx.addEllipse(in: bead); ctx.clip()
    let outer = CGMutablePath(); outer.addEllipse(in: bead.insetBy(dx: r * 0.07, dy: r * 0.07))
    let inner = CGMutablePath(); inner.addEllipse(in: bead.insetBy(dx: r * 0.07, dy: r * 0.07).offsetBy(dx: r * 0.10, dy: r * 0.13))
    ctx.addPath(outer); ctx.addPath(inner); ctx.clip(using: .evenOdd)
    ctx.drawLinearGradient(grad([c(1, 1, 1, 0.95), c(1, 1, 1, 0)], [0, 1]), start: CGPoint(x: ctr.x - r * 0.7, y: ctr.y - r * 0.7), end: CGPoint(x: ctr.x + r * 0.1, y: ctr.y + r * 0.1), options: [])
    ctx.restoreGState()

    // rim: bright on top, fading toward the bottom
    ctx.saveGState()
    ctx.addEllipse(in: bead.insetBy(dx: 1.5, dy: 1.5)); ctx.setLineWidth(3); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad([c(1, 1, 1, 1), c(1, 1, 1, 0.35)], [0, 1]), start: CGPoint(x: ctr.x, y: ctr.y - r), end: CGPoint(x: ctr.x, y: ctr.y + r), options: [])
    ctx.restoreGState()

    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
render(CommandLine.arguments[1])
