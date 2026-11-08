import Foundation

/// The pile of screenshots the fairy carries, as a pure value: which cards are held, which are
/// on their way out (animating), and a short memory of what recently left so it can be brought
/// back ("Restore Last Screenshot").
///
/// Every operation names the cards it acts on by id, so a capture that lands while another
/// delivery is still animating can never be swept away with it.
public struct HeldPile<Card: Identifiable> where Card.ID == UUID {
    public enum LeaveStyle: Equatable {
        /// Delivered, waiting for its turn to animate out (still drawn normally).
        case queued
        /// Shaken off: blur + fade.
        case dissolve
        /// Delivered: shrink towards the target.
        case drop
    }

    public enum ReleaseReason: Equatable {
        case shaken, discardedAll, delivered
        /// A capture that arrived from a screenshot session that had already ended on screen.
        case spurious
    }

    public struct ReleasedBatch {
        /// In pile order (oldest first).
        public let cards: [Card]
        public let reason: ReleaseReason
        public let at: TimeInterval
    }

    /// Oldest first; the last element is the top card.
    public private(set) var cards: [Card] = []
    public private(set) var leaving: [UUID: LeaveStyle] = [:]
    /// Most recent last.
    public private(set) var released: [ReleasedBatch] = []

    public var maxReleasedBatches: Int
    public var maxReleasedCards: Int
    /// Released cards older than this are forgotten (seconds).
    public var releaseTTL: TimeInterval

    public init(maxReleasedBatches: Int = 3, maxReleasedCards: Int = 8, releaseTTL: TimeInterval = 15 * 60) {
        self.maxReleasedBatches = maxReleasedBatches
        self.maxReleasedCards = maxReleasedCards
        self.releaseTTL = releaseTTL
    }

    // MARK: Queries

    /// Cards that gestures can still act on, oldest first.
    public var active: [Card] { cards.filter { leaving[$0.id] == nil } }
    /// Active cards, top (newest) first: the order a pile is delivered in.
    public var activeTopFirst: [Card] { active.reversed() }
    public var top: Card? { cards.last { leaving[$0.id] == nil } }
    public var isHolding: Bool { top != nil }
    public var isEmpty: Bool { cards.isEmpty }
    public var canRestore: Bool { !released.isEmpty }
    public func style(of id: UUID) -> LeaveStyle? { leaving[id] }
    public func card(_ id: UUID) -> Card? { cards.first { $0.id == id } }
    public func isActive(_ id: UUID) -> Bool { cards.contains { $0.id == id } && leaving[id] == nil }

    // MARK: Mutations

    public mutating func push(_ card: Card) {
        cards.append(card)
    }

    /// Mark the given (active) cards as leaving and remember them as one released batch.
    /// Returns the ids that were actually active.
    @discardableResult
    public mutating func beginLeaving(_ ids: [UUID], style: LeaveStyle, reason: ReleaseReason, now: TimeInterval) -> [UUID] {
        let taken = ids.filter { isActive($0) }
        guard !taken.isEmpty else { return [] }
        for id in taken { leaving[id] = style }
        remember(cards.filter { taken.contains($0.id) }, reason: reason, now: now)   // pile order
        return taken
    }

    /// Change the animation style of a card that is already leaving (queued → drop).
    public mutating func restyle(_ id: UUID, to style: LeaveStyle) {
        guard leaving[id] != nil else { return }
        leaving[id] = style
    }

    /// The leave animation finished: the card is gone from the pile (but still restorable).
    public mutating func finishLeaving(_ id: UUID) {
        guard leaving[id] != nil else { return }
        leaving[id] = nil
        cards.removeAll { $0.id == id }
    }

    /// Drop everything at once (no animation), remembering the active cards.
    public mutating func discardAll(reason: ReleaseReason, now: TimeInterval) {
        let gone = active
        if !gone.isEmpty { remember(gone, reason: reason, now: now) }
        cards.removeAll()
        leaving.removeAll()
    }

    /// Keep a card only in the released memory (never shown in the pile).
    public mutating func stash(_ card: Card, reason: ReleaseReason, now: TimeInterval) {
        remember([card], reason: reason, now: now)
    }

    /// Put the most recently released batch back on top of the pile. Cards still animating
    /// out are simply kept. Returns the restored cards.
    @discardableResult
    public mutating func restoreLast(now: TimeInterval) -> [Card] {
        prune(now: now)
        guard let batch = released.popLast() else { return [] }
        // Batches are kept in pile order (oldest first), so the old top ends up on top again.
        for card in batch.cards {
            if cards.contains(where: { $0.id == card.id }) {
                leaving[card.id] = nil
                // Move it to the top so it is the card gestures act on next.
                cards.removeAll { $0.id == card.id }
            }
            cards.append(card)
        }
        return batch.cards
    }

    public mutating func prune(now: TimeInterval) {
        released.removeAll { now - $0.at > releaseTTL }
    }

    private mutating func remember(_ gone: [Card], reason: ReleaseReason, now: TimeInterval) {
        prune(now: now)
        released.append(ReleasedBatch(cards: gone, reason: reason, at: now))
        while released.count > maxReleasedBatches { released.removeFirst() }
        // Bound memory: screenshots are big. Trim the oldest batches first, never the newest.
        while released.count > 1 && released.reduce(0, { $0 + $1.cards.count }) > maxReleasedCards {
            released.removeFirst()
        }
    }
}
