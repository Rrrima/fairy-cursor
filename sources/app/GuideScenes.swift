import FairyKit
import SwiftUI

// The small looping pictures in the welcome guide. Like the website: an empty white stage, one
// cursor, and only what the gesture needs. Every scene is a pure function of time, so a loop
// always plays the same way and any moment can be drawn on its own.

private typealias Ink = SettingsInk

/// The stage every scene is drawn on.
enum GuideStage {
    static let size = CGSize(width: 440, height: 210)
}

// MARK: - Motion

enum Ease {
    static func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (t - a) / (b - a))) }
    static func inOut(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
    /// In and out with a hair of overshoot at the far end, so a stop looks like it has weight.
    static func settle(_ p: Double) -> Double {
        let c = 1.15, c3 = c + 1
        let out = 1 + c3 * pow(p - 1, 3) + c * pow(p - 1, 2)
        return p < 0.5 ? inOut(p) : inOut(p) * (1 - (p - 0.5) * 2) + out * (p - 0.5) * 2
    }
}

/// Where the cursor is asked to be at each moment: points in time, eased between.
struct Track {
    let keys: [(t: Double, p: CGPoint)]

    init(_ keys: [(Double, CGFloat, CGFloat)]) {
        self.keys = keys.map { ($0.0, CGPoint(x: $0.1, y: $0.2)) }
    }

    func at(_ t: Double) -> CGPoint {
        guard let first = keys.first, let last = keys.last else { return .zero }
        if t <= first.t { return first.p }
        if t >= last.t { return last.p }
        let i = keys.firstIndex { $0.t > t } ?? keys.count - 1
        let a = keys[i - 1], b = keys[i]
        let e = Ease.settle((t - a.t) / (b.t - a.t))
        return CGPoint(x: a.p.x + (b.p.x - a.p.x) * e, y: a.p.y + (b.p.y - a.p.y) * e)
    }

    /// How fast it is moving sideways (points per second): the cursor and what it carries lean into it.
    func speedX(_ t: Double) -> Double { (at(t + 0.02).x - at(t - 0.02).x) / 0.04 }
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * p }
private func lean(_ speed: Double, _ k: Double = 0.016, limit: Double = 13) -> Double { min(limit, max(-limit, speed * k)) }

// MARK: - Pieces

/// The arrow: near-black with a white edge. Its tip is the hot spot; the body leans as it moves.
struct GuideCursor: View {
    var lean: Double = 0
    var scale: CGFloat = 1

    private static let tip = UnitPoint(x: 3.0 / 26, y: 3.0 / 26)

    var body: some View {
        ZStack {
            ArrowShape().fill(Ink.primary)
            ArrowShape().stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            ArrowShape().fill(Ink.primary)
        }
        .frame(width: 26, height: 26)
        .rotationEffect(.degrees(lean), anchor: Self.tip)
        .scaleEffect(scale, anchor: Self.tip)
        .shadow(color: .black.opacity(0.26), radius: 1.5, x: 0, y: 2)
    }

    private struct ArrowShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 3, y: 3))
            p.addLine(to: CGPoint(x: 9, y: 21.6))
            p.addLine(to: CGPoint(x: 12.3, y: 13.3))
            p.addLine(to: CGPoint(x: 20.6, y: 10))
            p.closeSubpath()
            return p
        }
    }
}

/// A picture on a page: the thing worth a screenshot.
private struct Picture: View {
    /// Left blank when something is going to be drawn on it.
    var glyph = true

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Ink.fill)
            .overlay(Image(systemName: "photo").font(.system(size: 26, weight: .light)).foregroundStyle(Ink.faint.opacity(0.75)).opacity(glyph ? 1 : 0))
    }
}

/// A piece of a page: a picture and two lines of text under it.
private struct Page: View {
    static let picture = CGRect(x: 44, y: 34, width: 168, height: 108)
    var glyph = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Picture(glyph: glyph).frame(width: Self.picture.width, height: Self.picture.height).offset(x: Self.picture.minX, y: Self.picture.minY)
            Capsule().fill(Ink.fill).frame(width: 168, height: 7).offset(x: 44, y: 156)
            Capsule().fill(Ink.fill).frame(width: 112, height: 7).offset(x: 44, y: 171)
        }
        .frame(width: GuideStage.size.width, height: GuideStage.size.height, alignment: .topLeading)
    }
}

/// A screenshot in hand: the picture with a white edge and a shadow.
private struct Sheet: View {
    var size: CGSize
    var video: String? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Ink.fill)
            .overlay(Image(systemName: "photo").font(.system(size: max(9, size.height * 0.3), weight: .light)).foregroundStyle(Ink.faint.opacity(0.75)))
            .overlay(alignment: .bottomTrailing) {
                if let video = video {
                    Text(video)
                        .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.55)))
                        .padding(4)
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).inset(by: -1.25).stroke(Color.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.2), radius: 9, x: 0, y: 7)
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }
}

/// A text box: somewhere a double-click can put things.
private struct Field: View {
    var caretX: CGFloat
    var blink: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Ink.fill)
            .frame(width: 160, height: 44)
            .overlay(alignment: .leading) {
                Rectangle().fill(Ink.primary).frame(width: 1.5, height: 17).offset(x: caretX).opacity(blink ? 1 : 0)
            }
    }
}

private let carried = CGSize(width: 84, height: 54)
private let hand = CGPoint(x: 17, y: 20)       // where a carried sheet hangs from the tip

/// Places a view with its top-left corner at a point on the stage.
private extension View {
    func at(_ p: CGPoint) -> some View { offset(x: p.x, y: p.y) }
    func stage() -> some View {
        frame(width: GuideStage.size.width, height: GuideStage.size.height, alignment: .topLeading)
    }
}

// MARK: - Scenes

/// A guide picture: how long its loop is, and how it looks at `t` seconds in.
struct GuideScene {
    let duration: Double
    let view: (Double) -> AnyView

    /// ⌘⇧4: drag a box over the picture, and it comes away in the cursor's hand.
    static let screenshot = GuideScene(duration: 5.2) { t in
        let pic = Page.picture
        let from = CGPoint(x: pic.minX - 6, y: pic.minY - 6), to = CGPoint(x: pic.maxX + 6, y: pic.maxY + 6)
        let track = Track([(0, 270, 160), (0.8, from.x, from.y), (1.0, from.x, from.y), (1.8, to.x, to.y),
                           (2.25, to.x, to.y), (3.2, 318, 84), (9, 318, 84)])
        let c = track.at(t)
        let dragging = t >= 1.0 && t < 1.85
        let taken = Ease.settle(Ease.ramp(t, 1.85, 2.5))
        let h = track.at(t - 0.07)
        let size = CGSize(width: mix(to.x - from.x, carried.width, taken), height: mix(to.y - from.y, carried.height, taken))
        let origin = CGPoint(x: mix(from.x, h.x + hand.x, taken), y: mix(from.y, h.y + hand.y, taken))
        return AnyView(ZStack(alignment: .topLeading) {
            Page()
            if t >= 1.0 && t < 2.2 {
                let end = dragging ? c : to
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.035))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.3), lineWidth: 1))
                    .frame(width: max(1, end.x - from.x), height: max(1, end.y - from.y))
                    .at(from)
                    .opacity(1 - Ease.ramp(t, 1.85, 2.15))
            }
            if t >= 1.85 {
                Sheet(size: size)
                    .rotationEffect(.degrees(-5 * taken + lean(track.speedX(t - 0.07), 0.014, limit: 11)), anchor: .topLeading)
                    .at(origin)
            }
            GuideCursor(lean: lean(track.speedX(t)), scale: dragging ? 0.86 : 1).at(CGPoint(x: c.x - 3, y: c.y - 3))
        }.stage())
    }

    /// Double-click a text box and what the cursor carries goes in.
    static let drop = GuideScene(duration: 4.4) { t in
        let track = Track([(0, 96, 132), (0.5, 96, 132), (1.5, 330, 104), (9, 330, 104)])
        let c = track.at(t), h = track.at(t - 0.07)
        let down = (t >= 1.75 && t < 1.86) || (t >= 1.98 && t < 2.09)
        let placed = Ease.settle(Ease.ramp(t, 2.1, 2.55))
        let field = CGPoint(x: 246, y: 80)
        let small = CGSize(width: 42, height: 27)
        let origin = CGPoint(x: mix(h.x + hand.x, field.x + 9, placed), y: mix(h.y + hand.y, field.y + 8.5, placed))
        let size = CGSize(width: mix(carried.width, small.width, placed), height: mix(carried.height, small.height, placed))
        return AnyView(ZStack(alignment: .topLeading) {
            Field(caretX: placed > 0.5 ? 60 : 14, blink: t.truncatingRemainder(dividingBy: 1) < 0.5 || t < 2.6).at(field)
            Sheet(size: size)
                .rotationEffect(.degrees((-5 + lean(track.speedX(t - 0.07), 0.014, limit: 11)) * (1 - placed)), anchor: .topLeading)
                .at(origin)
            GuideCursor(lean: lean(track.speedX(t)), scale: down ? 0.84 : 1).at(CGPoint(x: c.x - 3, y: c.y - 3))
        }.stage())
    }

    /// Shake, and the cursor lets go: the picture falls behind and dissolves.
    static let shake = GuideScene(duration: 3.0) { t in
        func x(_ t: Double) -> CGFloat {
            let p = Ease.ramp(t, 0.8, 1.9)
            return 196 + (p > 0 && p < 1 ? sin(p * .pi * 7) * 44 * (1 - p * 0.25) : 0)
        }
        let c = CGPoint(x: x(t), y: 78), h = CGPoint(x: x(t - 0.07), y: 78)
        let speed = (x(t + 0.02) - x(t - 0.02)) / 0.04
        let gone = Ease.ramp(t, 1.4, 1.95)
        // Once let go it stays where it was dropped, a little lower, and fades.
        let dropX = x(1.4 - 0.07)
        let origin = CGPoint(x: gone > 0 ? dropX + hand.x + 6 * gone : h.x + hand.x, y: h.y + hand.y + 26 * Ease.inOut(gone))
        return AnyView(ZStack(alignment: .topLeading) {
            Sheet(size: carried)
                .rotationEffect(.degrees(gone > 0 ? -5 * (1 - gone) : -5 + lean((x(t - 0.05) - x(t - 0.09)) / 0.04, 0.014, limit: 11)), anchor: .topLeading)
                .blur(radius: 8 * gone)
                .opacity(1 - gone)
                .at(origin)
            GuideCursor(lean: lean(speed)).at(CGPoint(x: c.x - 3, y: c.y - 3))
        }.stage())
    }

    /// ⌥ + click on empty space: a note opens from the cursor and remembers the page it was made on.
    static let note = GuideScene(duration: 5.6) { t in
        let spot = CGPoint(x: 236, y: 44)
        let track = Track([(0, 150, 176), (0.9, spot.x, spot.y), (1.5, spot.x, spot.y), (2.2, 412, 176), (9, 412, 176)])
        let c = track.at(t)
        let open = Ease.ramp(t, 1.3, 1.7)
        let grow = 0.3 + 0.7 * Ease.settle(open)
        let text = "look at this again"
        let typed = String(text.prefix(max(0, Int((t - 2.3) / 0.07))))
        let caret = t.truncatingRemainder(dividingBy: 1) < 0.5 || (t > 2.3 && t < 3.7)
        return AnyView(ZStack(alignment: .topLeading) {
            Page()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 9.5, weight: .medium))
                    Text("this page").font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Ink.secondary)
                .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.055)))
                .opacity(Ease.ramp(t, 1.65, 1.95))
                HStack(spacing: 1) {
                    Text(typed).font(.system(size: 13.5)).foregroundStyle(Ink.primary)
                    Rectangle().fill(Ink.primary).frame(width: 1.5, height: 15).opacity(caret ? 1 : 0)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .frame(width: 172, height: 104, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 10)
                    .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 2)
            )
            .scaleEffect(grow, anchor: .topLeading)
            .opacity(open)
            .at(spot)
            GuideCursor(lean: lean(track.speedX(t)), scale: t >= 1.15 && t < 1.28 ? 0.84 : 1).at(CGPoint(x: c.x - 3, y: c.y - 3))
        }.stage())
    }

    /// ⌘⇧6: a blue outline shows what's in the video. It zooms in around the cursor, the pen
    /// draws on screen, and two taps of ⌥ bring the whole screen back.
    static let record = GuideScene(duration: 7.4) { t in
        let whole = CGRect(x: 22, y: 20, width: 396, height: 176)
        let close = CGRect(x: 22, y: 32, width: 252, height: 252 * 176 / 396)
        let face = CGPoint(x: Page.picture.midX, y: Page.picture.midY - 2)
        let zoom = Ease.inOut(Ease.ramp(t, 1.7, 2.3)) - Ease.inOut(Ease.ramp(t, 4.9, 5.5))
        let area = CGRect(x: mix(whole.minX, close.minX, zoom), y: mix(whole.minY, close.minY, zoom),
                          width: mix(whole.width, close.width, zoom), height: mix(whole.height, close.height, zoom))
        let on = Ease.ramp(t, 0.6, 0.85)
        // The pen: two eyes, then a smile.
        let eye1 = Ease.ramp(t, 2.9, 3.05), eye2 = Ease.ramp(t, 3.2, 3.35), smile = Ease.inOut(Ease.ramp(t, 3.5, 4.0))
        func smilePoint(_ p: Double) -> CGPoint {
            let a = (158 - p * 136) * .pi / 180
            return CGPoint(x: face.x + 20 * cos(a), y: face.y - 3 + 20 * sin(a))
        }
        let drawing = t >= 2.7 && t < 4.3
        let track = Track([(0, 310, 160), (0.6, 310, 160), (1.5, face.x, face.y), (2.7, face.x, face.y), (2.9, face.x - 9, face.y - 15)])
        var c = track.at(t)
        if t >= 2.9 {
            if t < 3.05 { c = CGPoint(x: face.x - 9, y: face.y - 15 + 9 * eye1) }
            else if t < 3.2 { c = Track([(3.05, face.x - 9, face.y - 6), (3.2, face.x + 9, face.y - 15)]).at(t) }
            else if t < 3.35 { c = CGPoint(x: face.x + 9, y: face.y - 15 + 9 * eye2) }
            else if t < 3.5 { let s = smilePoint(0); c = Track([(3.35, face.x + 9, face.y - 6), (3.5, s.x, s.y)]).at(t) }
            else if t < 4.3 { c = smilePoint(smile) }
            else { let s = smilePoint(1); c = Track([(4.3, s.x, s.y), (5.0, 310, 150), (9, 310, 150)]).at(t) }
        }
        let ink = 1 - Ease.ramp(t, 6.6, 6.9)
        let secs = max(0, Int(t - 0.6))
        return AnyView(ZStack(alignment: .topLeading) {
            Page(glyph: false)
            Path { p in
                if eye1 > 0 { p.move(to: CGPoint(x: face.x - 9, y: face.y - 15)); p.addLine(to: CGPoint(x: face.x - 9, y: face.y - 15 + 9 * eye1)) }
                if eye2 > 0 { p.move(to: CGPoint(x: face.x + 9, y: face.y - 15)); p.addLine(to: CGPoint(x: face.x + 9, y: face.y - 15 + 9 * eye2)) }
                if smile > 0 {
                    p.move(to: smilePoint(0))
                    for i in 1...24 where Double(i) / 24 <= smile { p.addLine(to: smilePoint(Double(i) / 24)) }
                    p.addLine(to: smilePoint(smile))
                }
            }
            .stroke(Ink.accent, style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
            .opacity(ink)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Ink.accent, lineWidth: 2.5)
                .frame(width: area.width, height: area.height)
                .at(area.origin)
                .opacity(on)
            HStack(spacing: 5) {
                Circle().fill(Ink.accent).frame(width: 6.5, height: 6.5).opacity(0.45 + 0.55 * abs(sin(t * 1.3)))
                Text("0:0\(min(secs, 9))").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(Ink.primary)
            }
            .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 4)
            .background(Capsule().fill(.white).shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 3))
            .overlay(Capsule().strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
            .at(CGPoint(x: whole.maxX - 62, y: whole.minY - 9))
            .opacity(on)
            if drawing {
                Circle().fill(Ink.accent)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, x: 0, y: 1)
                    .at(CGPoint(x: c.x - 6.5, y: c.y - 6.5))
            } else {
                // The cursor is drawn bigger while a recording is running.
                GuideCursor(lean: lean(track.speedX(t)), scale: 1 + 0.3 * on).at(CGPoint(x: c.x - 3, y: c.y - 3))
            }
        }.stage())
    }
}

/// Plays a scene on a loop, fading across the seam. With "reduce motion" on (or when a moment is
/// pinned, for previews) it shows one telling frame instead.
struct GuideSceneView: View {
    let scene: GuideScene
    /// A fixed moment to draw; nil plays the loop.
    var pinned: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    var body: some View {
        Group {
            if let t = pinned ?? (reduceMotion ? scene.duration * 0.55 : nil) {
                scene.view(t)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSince(started).truncatingRemainder(dividingBy: scene.duration)
                    scene.view(t)
                        .opacity(min(Ease.ramp(t, 0, 0.3), 1 - Ease.ramp(t, scene.duration - 0.35, scene.duration)))
                }
            }
        }
        .frame(width: GuideStage.size.width, height: GuideStage.size.height)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
