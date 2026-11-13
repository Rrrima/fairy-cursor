import AppKit
import FairyCore
import SwiftUI

/// One screenshot the fairy is carrying.
struct HeldScreenshot: Identifiable {
    let id = UUID()
    let image: CGImage
    let scale: CGFloat
    let capturedAt: Date
    let nsImage: NSImage
    /// Small random tilt so stacked cards read as separate sheets.
    let tilt: Double

    init(image: CGImage, scale: CGFloat, capturedAt: Date = Date(), tilt: Double = 0) {
        self.image = image
        self.scale = scale
        self.capturedAt = capturedAt
        self.tilt = tilt
        self.nsImage = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    /// PNG with the display's DPI embedded so Preview/Finder show it at the right size.
    func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        return rep.representation(using: .png, properties: [:])
    }

    func tiffData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize
        return rep.tiffRepresentation
    }
}

@MainActor
final class FairyState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case holding
    }

    /// The carried pile (see `HeldPile`): cards, which ones are animating out, and what recently
    /// left (for "Restore Last Screenshot").
    @Published private(set) var pile = HeldPile<HeldScreenshot>()
    @Published var hint: String?
    /// Incremented to play the "no" wobble on the top sheet.
    @Published var rejectTick = 0
    /// True while the system screenshot UI is up; the fairy steps out of the way.
    @Published var hiddenForCapture = false

    private var hintTimer: Timer?
    private var pruneTimer: Timer?

    /// Every card on screen, oldest first (including ones animating out).
    var stack: [HeldScreenshot] { pile.cards }
    /// The card gestures act on.
    var top: HeldScreenshot? { pile.top }
    var isHolding: Bool { pile.isHolding }
    var phase: Phase { pile.isEmpty ? .idle : .holding }
    var canRestore: Bool { pile.canRestore }
    /// Cards a delivery takes, top first.
    var deliverable: [HeldScreenshot] { pile.activeTopFirst }
    func leaveStyle(of id: UUID) -> HeldPile<HeldScreenshot>.LeaveStyle? { pile.style(of: id) }
    func card(_ id: UUID) -> HeldScreenshot? { pile.isActive(id) ? pile.card(id) : nil }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// `kept`: the screenshot was already saved, so shaking only lets go of it.
    func hold(image: CGImage, scale: CGFloat, capturedAt: Date = Date(), kept: Bool = false) {
        pile.push(makeCard(image: image, scale: scale, capturedAt: capturedAt))
        let count = pile.active.count
        let verb = kept ? "saved · shake to let go" : "shake to discard"
        flashHint(count > 1 ? "\(count) screenshots · \(verb)" : verb, for: 2.4)
    }

    /// A capture we don't trust (from a screenshot session that had already ended on screen):
    /// keep it only in the restore memory instead of pushing it on the pile.
    func stash(image: CGImage, scale: CGFloat, capturedAt: Date = Date()) {
        pile.stash(makeCard(image: image, scale: scale, capturedAt: capturedAt), reason: .spurious, now: now)
        schedulePrune()
    }

    private func makeCard(image: CGImage, scale: CGFloat, capturedAt: Date) -> HeldScreenshot {
        // Alternate the tilt direction so each new sheet peeks out from the previous one.
        let sign: Double = pile.cards.count % 2 == 0 ? 1 : -1
        return HeldScreenshot(image: image, scale: scale, capturedAt: capturedAt, tilt: sign * Double.random(in: 8...15))
    }

    /// Shake off the top card.
    func dissolve() {
        guard let top = top else { return }
        let taken = pile.beginLeaving([top.id], style: .dissolve, reason: .shaken, now: now)
        guard !taken.isEmpty else { return }
        hint = nil
        finishLeaving(taken, after: 0.26)
        schedulePrune()
    }

    /// The given cards were delivered (pasted, saved, put in a note). They leave one after the
    /// other, top first; cards not in `ids` — e.g. a capture that lands meanwhile — stay.
    func deliver(ids: [UUID], hint text: String) {
        let taken = pile.beginLeaving(ids, style: .queued, reason: .delivered, now: now)
        // Keep the requested (top-first) order for the animation.
        let order = ids.filter { taken.contains($0) }
        for (k, id) in order.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.36) { [weak self] in
                guard let self = self, self.pile.style(of: id) == .queued else { return }
                self.pile.restyle(id, to: .drop)
                self.hint = text
                self.finishLeaving([id], after: 0.3)
            }
        }
        schedulePrune()
    }

    /// The target refused the screenshot: wobble, explain, keep holding.
    func reject(hint text: String) {
        guard isHolding else { return }
        rejectTick += 1
        flashHint(text, for: 2.4)
    }

    func discardAll() {
        pile.discardAll(reason: .discardedAll, now: now)
        hint = nil
        schedulePrune()
    }

    /// Bring back what last left the pile (shaken off, discarded, or delivered).
    func restoreLast() {
        let restored = pile.restoreLast(now: now)
        guard !restored.isEmpty else { return }
        flashHint(restored.count == 1 ? "restored" : "restored \(restored.count)", for: 1.6)
    }

    private func finishLeaving(_ ids: [UUID], after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // A restore while animating cancels the leave; finishLeaving then does nothing.
            ids.forEach { self.pile.finishLeaving($0) }
            if self.pile.isEmpty { self.hint = nil }
            else if let hint = self.hint { self.flashHint(hint, for: 1.2) }
        }
    }

    /// Forget released screenshots once they expire (they hold a lot of memory).
    private func schedulePrune() {
        pruneTimer?.invalidate()
        guard pile.canRestore else { return }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: pile.releaseTTL + 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.pile.prune(now: self.now)
                self.schedulePrune()
            }
        }
    }

    func flashHint(_ text: String, for seconds: TimeInterval) {
        hint = text
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.hint == text { self?.hint = nil }
            }
        }
    }

    /// Context hint while hovering a target (cleared when nil).
    func setHoverHint(_ text: String?) {
        guard isHolding else { return }
        if let text = text {
            hintTimer?.invalidate()
            hint = text
        } else if !(hint?.contains("shake") ?? false) {
            hint = nil
        }
    }
}
