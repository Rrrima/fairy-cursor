import Foundation
import XCTest
@testable import FairyCore

/// Runs the outcome and restore rules together over a simulated timeline, like `PasteJob` does
/// (polling every 50 ms / 100 ms after ⌘V).
private struct Timeline {
    var hasProbe = false
    /// Times (after ⌘V) at which the target reads the promised data.
    var reads: [TimeInterval] = []
    /// Time at which the probe first sees a change.
    var probeChangesAt: TimeInterval?
    /// Time at which someone else writes the pasteboard.
    var foreignWriteAt: TimeInterval?

    struct Result { var outcome: PastePolicy.Outcome; var decidedAt: TimeInterval; var restoreAt: TimeInterval?; var restored: Bool }

    func run() -> Result {
        let outcomeRules = PastePolicy.OutcomeRules(hasProbe: hasProbe)
        let restoreRules = PastePolicy.RestoreRules()
        var outcome = PastePolicy.Outcome.pending
        var decidedAt = 0.0
        var restoreAt: TimeInterval?
        var restored = false
        var t = 0.0
        while t < 10 && (outcome == .pending || restoreAt == nil) {
            let readsSoFar = reads.filter { $0 <= t }
            if outcome == .pending {
                let o = outcomeRules.evaluate(elapsed: t, reads: readsSoFar.count, probeChanged: probeChangesAt.map { $0 <= t } ?? false)
                if o != .pending { outcome = o; decidedAt = t }
            }
            if restoreAt == nil {
                let unchanged = foreignWriteAt.map { t < $0 } ?? true
                switch restoreRules.step(sinceSend: t, sinceLastRead: readsSoFar.last.map { t - $0 }, pasteboardUnchanged: unchanged) {
                case .wait: break
                case .restore: restoreAt = t; restored = true
                case .abandon: restoreAt = t; restored = false
                }
            }
            t += 0.05
        }
        return Result(outcome: outcome, decidedAt: decidedAt, restoreAt: restoreAt, restored: restored)
    }
}

final class PasteTimelineTests: XCTestCase {
    func testBrowserComposerReadsImmediately() {
        let r = Timeline(reads: [0.03, 0.04]).run()
        XCTAssertEqual(r.outcome, .accepted)
        XCTAssertLessThan(r.decidedAt, 0.3)
        XCTAssertTrue(r.restored)
        XCTAssertGreaterThanOrEqual(r.restoreAt ?? 0, 2.0)
    }

    func testAppIgnoringCmdVKeepsTheScreenshotAndRestoresClipboard() {
        // The ChatGPT failure: ⌘V never reached a paste handler.
        let r = Timeline(reads: []).run()
        XCTAssertEqual(r.outcome, .failed)
        XCTAssertTrue(r.restored)
    }

    func testSlowNativeAppReadingLateIsNotCutOff() {
        // Reads after an async hop, 1.4 s in, then again at 1.8 s (preview, then upload).
        let r = Timeline(reads: [1.4, 1.8]).run()
        XCTAssertEqual(r.outcome, .accepted)
        XCTAssertGreaterThanOrEqual(r.restoreAt ?? 0, 2.4 - 0.001, "restore waits until reads go quiet")
    }

    func testSearchFieldRefusesImage() {
        // Single-line field: looked at the pasteboard types, never read image data.
        let r = Timeline(hasProbe: true, reads: []).run()
        XCTAssertEqual(r.outcome, .failed)
    }

    func testAddressBarReadsButStaysUnchanged() {
        let r = Timeline(hasProbe: true, reads: [0.05]).run()
        XCTAssertEqual(r.outcome, .rejected)
    }

    func testSingleLineFieldThatTakesTheImage() {
        let r = Timeline(hasProbe: true, reads: [0.05], probeChangesAt: 0.4).run()
        XCTAssertEqual(r.outcome, .accepted)
    }

    func testUserCopiesSomethingRightAfterThePaste() {
        let r = Timeline(reads: [0.05], foreignWriteAt: 0.8).run()
        XCTAssertEqual(r.outcome, .accepted)
        XCTAssertFalse(r.restored, "never overwrite what the user copied")
    }

    func testNextPasteOfAPileSupersedesTheRestore() {
        // The second card is written ~0.75 s later; the first job must not restore over it.
        let r = Timeline(reads: [0.05], foreignWriteAt: 0.75).run()
        XCTAssertFalse(r.restored)
    }
}
