import Foundation
import XCTest
@testable import FairyCore

private struct Card: Identifiable, Equatable {
    let id = UUID()
    let name: String
}

final class HeldPileTests: XCTestCase {
    private func pile(_ names: String...) -> (HeldPile<Card>, [Card]) {
        var p = HeldPile<Card>()
        let cards = names.map { Card(name: $0) }
        cards.forEach { p.push($0) }
        return (p, cards)
    }

    func testEmpty() {
        let p = HeldPile<Card>()
        XCTAssertFalse(p.isHolding)
        XCTAssertNil(p.top)
        XCTAssertTrue(p.isEmpty)
        XCTAssertFalse(p.canRestore)
    }

    func testTopIsNewest() {
        let (p, c) = pile("a", "b", "c")
        XCTAssertEqual(p.top, c[2])
        XCTAssertEqual(p.activeTopFirst.map(\.name), ["c", "b", "a"])
    }

    func testLeavingCardIsNotTopAndNotActive() {
        var (p, c) = pile("a", "b")
        p.beginLeaving([c[1].id], style: .dissolve, reason: .shaken, now: 0)
        XCTAssertEqual(p.top, c[0])
        XCTAssertEqual(p.cards.count, 2, "still drawn while animating")
        XCTAssertEqual(p.style(of: c[1].id), .dissolve)
        p.finishLeaving(c[1].id)
        XCTAssertEqual(p.cards, [c[0]])
    }

    func testCaptureDuringLeaveAnimationIsNotSweptAway() {
        // Old bug: dropAll kept dropping "the top" until empty, taking a capture that landed
        // mid-delivery with it (never saved/pasted anywhere).
        var (p, c) = pile("a", "b")
        let delivered = p.beginLeaving(p.activeTopFirst.map(\.id), style: .queued, reason: .delivered, now: 0)
        XCTAssertEqual(Set(delivered), Set(c.map(\.id)))
        let fresh = Card(name: "fresh")
        p.push(fresh)
        delivered.forEach { p.finishLeaving($0) }
        XCTAssertEqual(p.cards, [fresh])
        XCTAssertEqual(p.top, fresh)
    }

    func testOverlappingLeavesBothComplete() {
        // Old bug: a second dissolve overwrote the single `leavingID`, so the first card's
        // finish was skipped and it came back.
        var (p, c) = pile("a", "b", "c")
        p.beginLeaving([c[2].id], style: .drop, reason: .delivered, now: 0)
        p.beginLeaving([c[1].id], style: .dissolve, reason: .shaken, now: 0.1)
        p.finishLeaving(c[2].id)
        p.finishLeaving(c[1].id)
        XCTAssertEqual(p.cards, [c[0]])
    }

    func testBeginLeavingIgnoresUnknownAndAlreadyLeaving() {
        var (p, c) = pile("a")
        XCTAssertEqual(p.beginLeaving([UUID()], style: .drop, reason: .delivered, now: 0), [])
        XCTAssertEqual(p.beginLeaving([c[0].id], style: .drop, reason: .delivered, now: 0), [c[0].id])
        XCTAssertEqual(p.beginLeaving([c[0].id], style: .drop, reason: .delivered, now: 0), [])
        XCTAssertEqual(p.released.count, 1)
    }

    func testFinishLeavingOfActiveCardIsNoOp() {
        var (p, c) = pile("a")
        p.finishLeaving(c[0].id)
        XCTAssertEqual(p.cards, c)
    }

    func testRestoreAfterShake() {
        var (p, c) = pile("a", "b")
        p.beginLeaving([c[1].id], style: .dissolve, reason: .shaken, now: 0)
        p.finishLeaving(c[1].id)
        XCTAssertTrue(p.canRestore)
        XCTAssertEqual(p.restoreLast(now: 1), [c[1]])
        XCTAssertEqual(p.cards, [c[0], c[1]])
        XCTAssertEqual(p.top, c[1])
        XCTAssertFalse(p.canRestore)
    }

    func testRestoreWhileStillAnimatingCancelsTheLeave() {
        var (p, c) = pile("a", "b")
        p.beginLeaving([c[1].id], style: .dissolve, reason: .shaken, now: 0)
        p.restoreLast(now: 0.1)
        XCTAssertEqual(p.cards.map(\.name), ["a", "b"], "no duplicate")
        XCTAssertNil(p.style(of: c[1].id))
        p.finishLeaving(c[1].id)   // late animation completion must not remove it
        XCTAssertEqual(p.cards.count, 2)
    }

    func testRestoreDiscardAllKeepsOrder() {
        var (p, c) = pile("a", "b", "c")
        p.discardAll(reason: .discardedAll, now: 0)
        XCTAssertTrue(p.isEmpty)
        p.restoreLast(now: 1)
        XCTAssertEqual(p.cards, c)
        XCTAssertEqual(p.top, c[2])
    }

    func testRestoreDeliveredPileKeepsOrder() {
        var (p, c) = pile("a", "b", "c")
        let ids = p.beginLeaving(p.activeTopFirst.map(\.id), style: .queued, reason: .delivered, now: 0)
        ids.forEach { p.finishLeaving($0) }
        p.restoreLast(now: 1)
        XCTAssertEqual(p.cards, c)
    }

    func testRestoreGoesOnTopOfNewerCards() {
        var (p, c) = pile("a")
        p.beginLeaving([c[0].id], style: .dissolve, reason: .shaken, now: 0)
        p.finishLeaving(c[0].id)
        let b = Card(name: "b")
        p.push(b)
        p.restoreLast(now: 1)
        XCTAssertEqual(p.cards.map(\.name), ["b", "a"])
    }

    func testReleasedMemoryIsBoundedByBatches() {
        var p = HeldPile<Card>(maxReleasedBatches: 2, maxReleasedCards: 100)
        for i in 0..<5 {
            let card = Card(name: "\(i)")
            p.push(card)
            p.beginLeaving([card.id], style: .dissolve, reason: .shaken, now: Double(i))
            p.finishLeaving(card.id)
        }
        XCTAssertEqual(p.released.count, 2)
        XCTAssertEqual(p.restoreLast(now: 5).map(\.name), ["4"])
        XCTAssertEqual(p.restoreLast(now: 5).map(\.name), ["3"])
        XCTAssertEqual(p.restoreLast(now: 5), [])
    }

    func testReleasedMemoryIsBoundedByCardsButKeepsNewestBatch() {
        var p = HeldPile<Card>(maxReleasedBatches: 5, maxReleasedCards: 3)
        let many = (0..<5).map { Card(name: "m\($0)") }
        many.forEach { p.push($0) }
        p.discardAll(reason: .discardedAll, now: 0)
        XCTAssertEqual(p.released.count, 1, "newest batch is kept even when over the card budget")
        let one = Card(name: "one")
        p.push(one)
        p.beginLeaving([one.id], style: .dissolve, reason: .shaken, now: 1)
        XCTAssertEqual(p.released.count, 1, "older over-budget batch dropped")
        XCTAssertEqual(p.released.last?.cards, [one])
    }

    func testReleasedExpires() {
        var p = HeldPile<Card>(releaseTTL: 60)
        let card = Card(name: "a")
        p.push(card)
        p.discardAll(reason: .discardedAll, now: 0)
        XCTAssertEqual(p.restoreLast(now: 61), [])
    }

    func testStashOnlyGoesToMemory() {
        var p = HeldPile<Card>()
        let ghost = Card(name: "ghost")
        p.stash(ghost, reason: .spurious, now: 0)
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.released.last?.reason, .spurious)
        XCTAssertEqual(p.restoreLast(now: 1), [ghost])
        XCTAssertEqual(p.top, ghost)
    }

    func testDiscardAllWithNothingActiveRemembersNothing() {
        var p = HeldPile<Card>()
        p.discardAll(reason: .discardedAll, now: 0)
        XCTAssertFalse(p.canRestore)
    }

    func testRestyleQueuedToDrop() {
        var (p, c) = pile("a")
        p.beginLeaving([c[0].id], style: .queued, reason: .delivered, now: 0)
        p.restyle(c[0].id, to: .drop)
        XCTAssertEqual(p.style(of: c[0].id), .drop)
        p.restyle(UUID(), to: .drop)   // unknown: no-op
    }
}
