import FairyCore
import SwiftUI

/// Geometry shared with the panel/follower.
enum FairyLayout {
    /// Room for the stack plus its soft shadow and tilt.
    static let panelSize = CGSize(width: 200, height: 170)
    /// Inset from the panel's top-left to the content's top-left (shadow + tilt bleed).
    static let inset: CGFloat = 18
    static let thumbMax = CGSize(width: 112, height: 84)
    static let orbSize: CGFloat = 14
    /// How many sheets of the stack are drawn (older ones hide underneath).
    static let visibleCards = 4
}

struct FairyView: View {
    @ObservedObject var state: FairyState

    var body: some View {
        // No GlassEffectContainer: it renders the glass shapes itself and ignores the per-card
        // rotation, so each card carries its own standalone glass effect.
        ZStack(alignment: .topLeading) {
            // Nothing held, nothing shown: the fairy only appears while carrying something.
            if !state.stack.isEmpty {
                stack
            }
        }
        .padding(FairyLayout.inset)
        .frame(width: FairyLayout.panelSize.width, height: FairyLayout.panelSize.height, alignment: .topLeading)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: state.stack.map(\.id))
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: state.phase)
        .animation(.easeOut(duration: 0.18), value: state.hint)
        .opacity(state.hiddenForCapture ? 0 : 1)
        .animation(.easeInOut(duration: 0.15), value: state.hiddenForCapture)
    }

    // MARK: Stack — newest sheet on top, each tilted a little; the hint sits below the pile.

    private var stack: some View {
        let visible = Array(state.stack.suffix(FairyLayout.visibleCards))
        let topID = state.stack.last?.id
        return VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, shot in
                    let depth = visible.count - 1 - index          // 0 = top
                    sheet(shot, isTop: shot.id == topID, depth: depth)
                        .modifier(Wobble(phase: shot.id == topID ? CGFloat(state.rejectTick) : 0))
                        .animation(.easeInOut(duration: 0.42), value: state.rejectTick)
                        .offset(x: CGFloat(depth) * 3, y: CGFloat(depth) * -4)
                        .zIndex(Double(index))
                        .transition(.scale(scale: 0.45, anchor: .topLeading).combined(with: .opacity))
                }
            }
            if let hint = state.hint {
                Text(hint)
                    .font(Theme.font(11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .fixedSize()                                      // wider than the pile is fine
                    .shadow(color: .white.opacity(0.9), radius: 2)   // legible over any desktop
                    .padding(.leading, 2)
                    .transition(.opacity)
            }
        }
    }

    /// One sheet: the screenshot itself is the container — rounded, hairlined, tilted. The glass
    /// effect is not transformed (SwiftUI renders a transformed glass layer at the hosting view's
    /// full size), so the image is rotated and the glass gets a rotated shape of the same angle.
    private func sheet(_ shot: HeldScreenshot, isTop: Bool, depth: Int) -> some View {
        let style = state.leaveStyle(of: shot.id)
        let dissolving = style == .dissolve
        let dropping = style == .drop
        let leaving = dissolving || dropping
        let shrink = 1 - CGFloat(depth) * 0.05
        // A lone screenshot sits straight; tilts only appear once there is a pile.
        let angle = Angle.degrees(state.stack.count > 1 ? shot.tilt : 0)
        let shape = RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
        let tilted = shape.rotation(angle)

        return Image(nsImage: shot.nsImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: FairyLayout.thumbMax.width * shrink, maxHeight: FairyLayout.thumbMax.height * shrink)
            .clipShape(shape)
            .rotationEffect(angle)
            .glassEffect(.regular.tint(.white.opacity(0.15)), in: tilted)
            .overlay(tilted.stroke(Theme.hairlineStrong, lineWidth: 1))
            .overlay(tilted.stroke(Theme.rim, lineWidth: 1).padding(0.5))
            .glassShadow(isTop ? 1 : 0.6)
            .scaleEffect(dissolving ? 0.72 : (dropping ? 0.35 : 1), anchor: dropping ? .topLeading : .center)
            .blur(radius: dissolving ? 7 : 0)
            .opacity(dissolving || dropping ? 0 : 1)
            .animation(.easeIn(duration: dissolving ? 0.22 : 0.26), value: leaving)
    }
}

/// A quick side-to-side "no": three damped swings per unit of `phase`.
struct Wobble: GeometryEffect {
    var phase: CGFloat
    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = phase - floor(phase)                       // 0…1 within the current wobble
        let amplitude: CGFloat = 7 * (1 - t)               // damp out
        let dx = sin(t * .pi * 6) * amplitude
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}
