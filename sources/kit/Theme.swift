import AppKit
import SwiftUI

/// Visual tokens ported from agentic-web's "Liquid Clarity" glass system
/// (host/resources/chrome/styles.css): cool blue-grey neutrals, hairline borders,
/// a white 135° plate over live glass, one blue accent used only for "live" marks.
public enum Theme {
    /// rgba(28, 38, 58, …) — the base for hairlines and shadows.
    public static let slate = Color(red: 28 / 255, green: 38 / 255, blue: 58 / 255)
    /// --text #2a3346
    public static let text = Color(red: 0x2a / 255, green: 0x33 / 255, blue: 0x46 / 255)
    /// --muted #5a6478
    public static let muted = Color(red: 0x5a / 255, green: 0x64 / 255, blue: 0x78 / 255)
    /// --accent #3b82f6, the one accent.
    public static let accent = Color(red: 0x3b / 255, green: 0x82 / 255, blue: 0xf6 / 255)

    /// --border rgba(28,38,58,.08)
    public static let hairline = slate.opacity(0.08)
    /// --border-strong rgba(28,38,58,.14)
    public static let hairlineStrong = slate.opacity(0.14)

    /// Barlow (agentic-web's UI face), bundled from resources/fonts and registered at launch.
    public static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "Barlow-SemiBold"
        case .medium: name = "Barlow-Medium"
        default: name = "Barlow-Regular"
        }
        return .custom(name, size: size)
    }

    public static let radius: CGFloat = 14
    public static let radiusSm: CGFloat = 8

    /// --glass-grad-half: white → #f8fafd plate, kept translucent so the glass refraction shows.
    public static let plate = LinearGradient(
        colors: [
            Color.white.opacity(0.50),
            Color(red: 248 / 255, green: 250 / 255, blue: 253 / 255).opacity(0.38),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// --glass-inset: inset 0 1px 0 rgba(255,255,255,.75) — a top rim highlight.
    public static let rim = LinearGradient(
        colors: [Color.white.opacity(0.78), Color.white.opacity(0.18), Color.white.opacity(0.0)],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// --glass-shadow: soft slate lift + tight contact shadow.
public struct GlassShadow: ViewModifier {
    public var strength: CGFloat = 1
    public init(strength: CGFloat = 1) { self.strength = strength }
    public func body(content: Content) -> some View {
        content
            .shadow(color: Theme.slate.opacity(0.09 * strength), radius: 16, x: 0, y: 10)
            .shadow(color: Theme.slate.opacity(0.06 * strength), radius: 4, x: 0, y: 2)
    }
}

extension View {
    /// The shared glass surface for floating panels and cards.
    @ViewBuilder
    public func fairyGlass<S: Shape>(tint: Color, in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            background {
                FrostedGlass()
                    .clipShape(shape)
                    .overlay(shape.fill(tint))
                    .allowsHitTesting(false)
            }
        }
    }

    public func glassShadow(_ strength: CGFloat = 1) -> some View { modifier(GlassShadow(strength: strength)) }
}

private struct FrostedGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        // The panels use fixed dark text, so keep the backdrop light in either appearance.
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Layered slate shadow — a crisp contact edge, a mid key shadow and a wide ambient one — with
/// the card's own shape cut out, so it never shows through translucent glass as a grey haze.
/// `lift` scales the spread: small things sit close to the surface, a note floats higher.
public struct CardShadow<S: Shape>: View {
    let shape: S
    var lift: CGFloat = 1

    public init(shape: S, lift: CGFloat = 1) {
        self.shape = shape
        self.lift = lift
    }

    public var body: some View {
        ZStack {
            layer(opacity: 0.10, blur: 0.8, y: 0.6)                   // contact: defines the edge
            layer(opacity: 0.07, blur: 5 * lift, y: 3 * lift)         // key: the main lift
            layer(opacity: 0.06, blur: 16 * lift, y: 12 * lift)       // ambient: soft, far, low
        }
        .mask {
            Rectangle()
                .padding(-80)
                .overlay(shape.blendMode(.destinationOut))
                .compositingGroup()
        }
        .allowsHitTesting(false)
    }

    private func layer(opacity: Double, blur: CGFloat, y: CGFloat) -> some View {
        shape
            .fill(Theme.slate.opacity(opacity))
            .blur(radius: blur)
            .offset(y: y)
    }
}
