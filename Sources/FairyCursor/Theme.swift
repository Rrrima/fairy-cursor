import SwiftUI

/// Visual tokens ported from agentic-web's "Liquid Clarity" glass system
/// (host/resources/chrome/styles.css): cool blue-grey neutrals, hairline borders,
/// a white 135° plate over live glass, one blue accent used only for "live" marks.
enum Theme {
    /// rgba(28, 38, 58, …) — the base for hairlines and shadows.
    static let slate = Color(red: 28 / 255, green: 38 / 255, blue: 58 / 255)
    /// --text #2a3346
    static let text = Color(red: 0x2a / 255, green: 0x33 / 255, blue: 0x46 / 255)
    /// --muted #5a6478
    static let muted = Color(red: 0x5a / 255, green: 0x64 / 255, blue: 0x78 / 255)
    /// --accent #3b82f6, the one accent.
    static let accent = Color(red: 0x3b / 255, green: 0x82 / 255, blue: 0xf6 / 255)

    /// --border rgba(28,38,58,.08)
    static let hairline = slate.opacity(0.08)
    /// --border-strong rgba(28,38,58,.14)
    static let hairlineStrong = slate.opacity(0.14)

    /// Barlow (agentic-web's UI face), bundled in Resources/Fonts and registered at launch.
    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .semibold, .bold, .heavy, .black: name = "Barlow-SemiBold"
        case .medium: name = "Barlow-Medium"
        default: name = "Barlow-Regular"
        }
        return .custom(name, size: size)
    }

    static let radius: CGFloat = 14
    static let radiusSm: CGFloat = 8

    /// --glass-grad-half: white → #f8fafd plate, kept translucent so the glass refraction shows.
    static let plate = LinearGradient(
        colors: [
            Color.white.opacity(0.50),
            Color(red: 248 / 255, green: 250 / 255, blue: 253 / 255).opacity(0.38),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// --glass-inset: inset 0 1px 0 rgba(255,255,255,.75) — a top rim highlight.
    static let rim = LinearGradient(
        colors: [Color.white.opacity(0.78), Color.white.opacity(0.18), Color.white.opacity(0.0)],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// --glass-shadow: soft slate lift + tight contact shadow.
struct GlassShadow: ViewModifier {
    var strength: CGFloat = 1
    func body(content: Content) -> some View {
        content
            .shadow(color: Theme.slate.opacity(0.09 * strength), radius: 16, x: 0, y: 10)
            .shadow(color: Theme.slate.opacity(0.06 * strength), radius: 4, x: 0, y: 2)
    }
}

extension View {
    func glassShadow(_ strength: CGFloat = 1) -> some View { modifier(GlassShadow(strength: strength)) }
}
