import Foundation
import XCTest
@testable import FairyCore

final class PastePolicyTests: XCTestCase {
    // MARK: Key routing

    func testFrontmostTargetUsesSessionStream() {
        XCTAssertEqual(PastePolicy.keyRoute(target: 42, frontmost: 42), .session)
        XCTAssertFalse(PastePolicy.needsActivation(target: 42, frontmost: 42))
    }

    func testUnknownTargetUsesSessionStream() {
        XCTAssertEqual(PastePolicy.keyRoute(target: nil, frontmost: 42), .session)
        XCTAssertEqual(PastePolicy.keyRoute(target: 0, frontmost: 42), .session)
        XCTAssertEqual(PastePolicy.keyRoute(target: -1, frontmost: nil), .session)
        XCTAssertFalse(PastePolicy.needsActivation(target: nil, frontmost: 42))
    }

    func testBackgroundTargetIsActivatedThenFallsBackToPid() {
        XCTAssertTrue(PastePolicy.needsActivation(target: 42, frontmost: 7))
        XCTAssertEqual(PastePolicy.keyRoute(target: 42, frontmost: 7), .process(42))
        XCTAssertTrue(PastePolicy.needsActivation(target: 42, frontmost: nil))
    }

    // MARK: Mouse-up wait

    func testWaitsForRelease() {
        XCTAssertEqual(PastePolicy.mouseUpStep(elapsed: 0.05, buttonsDown: true), .wait)
        XCTAssertEqual(PastePolicy.mouseUpStep(elapsed: 0.05, buttonsDown: false), .proceed)
    }

    func testDoesNotWaitForeverOnAHeldButton() {
        XCTAssertEqual(PastePolicy.mouseUpStep(elapsed: PastePolicy.mouseUpTimeout, buttonsDown: true), .proceed)
    }

    // MARK: Outcome

    func testMultilineReadMeansAccepted() {
        let r = PastePolicy.OutcomeRules(hasProbe: false)
        XCTAssertEqual(r.evaluate(elapsed: 0.05, reads: 1, probeChanged: false), .pending)
        XCTAssertEqual(r.evaluate(elapsed: 0.2, reads: 1, probeChanged: false), .accepted)
    }

    func testMultilineNoReadMeansFailedNotSilentlyDropped() {
        // The old code assumed every multi-line paste was accepted, so a ⌘V the app ignored
        // (ChatGPT) dropped the screenshot — and the clipboard was restored, so it was gone.
        let r = PastePolicy.OutcomeRules(hasProbe: false)
        XCTAssertEqual(r.evaluate(elapsed: 1.0, reads: 0, probeChanged: false), .pending)
        XCTAssertEqual(r.evaluate(elapsed: 1.6, reads: 0, probeChanged: false), .failed)
    }

    func testProbeChangeAcceptsImmediately() {
        let r = PastePolicy.OutcomeRules(hasProbe: true)
        XCTAssertEqual(r.evaluate(elapsed: 0.15, reads: 0, probeChanged: true), .accepted)
    }

    func testSingleLineReadButUnchangedIsRejected() {
        let r = PastePolicy.OutcomeRules(hasProbe: true)
        XCTAssertEqual(r.evaluate(elapsed: 2.0, reads: 2, probeChanged: false), .pending)
        XCTAssertEqual(r.evaluate(elapsed: 3.0, reads: 2, probeChanged: false), .rejected)
    }

    func testSingleLineNoReadFailsEarly() {
        let r = PastePolicy.OutcomeRules(hasProbe: true)
        XCTAssertEqual(r.evaluate(elapsed: 1.6, reads: 0, probeChanged: false), .failed)
    }

    func testOutcomeIsMonotonicOverTime() {
        // Once decided at time t, the same signals at a later time give the same decision.
        for hasProbe in [false, true] {
            let r = PastePolicy.OutcomeRules(hasProbe: hasProbe)
            for reads in [0, 1] {
                var decided: PastePolicy.Outcome?
                for step in 0...80 {
                    let o = r.evaluate(elapsed: Double(step) * 0.05, reads: reads, probeChanged: false)
                    if let d = decided, o != d, !(d == .pending) {
                        XCTFail("probe=\(hasProbe) reads=\(reads): \(d) → \(o)")
                    }
                    if o != .pending { decided = decided ?? o }
                }
                XCTAssertNotNil(decided, "always decides eventually")
            }
        }
    }

    // MARK: Clipboard restore

    func testNeverRestoresBeforeMinDelay() {
        let r = PastePolicy.RestoreRules()
        XCTAssertEqual(r.step(sinceSend: 1.2, sinceLastRead: 1.0, pasteboardUnchanged: true), .wait)
    }

    func testRestoresAfterQuietRead() {
        let r = PastePolicy.RestoreRules()
        XCTAssertEqual(r.step(sinceSend: 2.1, sinceLastRead: 0.9, pasteboardUnchanged: true), .restore)
    }

    func testWaitsWhileTheAppIsStillReading() {
        let r = PastePolicy.RestoreRules()
        XCTAssertEqual(r.step(sinceSend: 2.5, sinceLastRead: 0.2, pasteboardUnchanged: true), .wait)
    }

    func testWithoutAnyReadHoldsTheScreenshotLonger() {
        // The ⌘V may still be queued in a busy app: restoring now would paste the user's text.
        let r = PastePolicy.RestoreRules()
        XCTAssertEqual(r.step(sinceSend: 2.0, sinceLastRead: nil, pasteboardUnchanged: true), .wait)
        XCTAssertEqual(r.step(sinceSend: 6.0, sinceLastRead: nil, pasteboardUnchanged: true), .wait)
        XCTAssertEqual(r.step(sinceSend: 8.0, sinceLastRead: nil, pasteboardUnchanged: true), .restore)
    }

    func testRestoresByMaxDelayEvenIfReadsContinue() {
        let r = PastePolicy.RestoreRules()
        XCTAssertEqual(r.step(sinceSend: 6.0, sinceLastRead: 0.01, pasteboardUnchanged: true), .restore)
    }

    func testAbandonsWhenSomeoneElseWroteThePasteboard() {
        let r = PastePolicy.RestoreRules()
        XCTAssertEqual(r.step(sinceSend: 0.1, sinceLastRead: nil, pasteboardUnchanged: false), .abandon)
        XCTAssertEqual(r.step(sinceSend: 9, sinceLastRead: nil, pasteboardUnchanged: false), .abandon)
    }

    // MARK: Pasteboard contents

    func testImageTypes() {
        XCTAssertEqual(PastePolicy.imageTypes(forTerminal: false), ["public.png", "public.tiff"])
        let t = PastePolicy.imageTypes(forTerminal: true)
        XCTAssertTrue(t.contains("public.utf8-plain-text"))
        XCTAssertTrue(t.contains("public.png"))
    }

    func testShellQuoting() {
        XCTAssertEqual(PastePolicy.shellQuoted("/Users/a/Pictures/x.png"), "/Users/a/Pictures/x.png ")
        XCTAssertEqual(PastePolicy.shellQuoted("/Users/a/Fairy Cursor/Screenshot 1.png"), "'/Users/a/Fairy Cursor/Screenshot 1.png' ")
        XCTAssertEqual(PastePolicy.shellQuoted("/tmp/it's.png"), "'/tmp/it'\\''s.png' ")
        XCTAssertEqual(PastePolicy.shellQuoted("/tmp/a(1).png"), "'/tmp/a(1).png' ")
    }
}

final class TerminalClipboardTests: XCTestCase {
    private let settle = PastePolicy.TerminalSettle()

    func testWaitsWhileAThirdClickIsHeld() {
        XCTAssertEqual(settle.step(elapsed: 0.3, buttonsDown: true, sinceMouseUp: 0.3, sinceClipboardChange: nil), .wait)
    }

    func testWaitsForTheCopyOnSelectAfterTheLastMouseUp() {
        // iTerm copies the selection ~10 ms after each mouse-up.
        XCTAssertEqual(settle.step(elapsed: 0.05, buttonsDown: false, sinceMouseUp: 0.05, sinceClipboardChange: nil), .wait)
        XCTAssertEqual(settle.step(elapsed: 0.2, buttonsDown: false, sinceMouseUp: 0.2, sinceClipboardChange: nil), .proceed)
    }

    func testAThirdClickRestartsTheWait() {
        XCTAssertEqual(settle.step(elapsed: 0.5, buttonsDown: false, sinceMouseUp: 0.02, sinceClipboardChange: nil), .wait)
    }

    func testWaitsWhileTheClipboardIsStillChanging() {
        XCTAssertEqual(settle.step(elapsed: 0.3, buttonsDown: false, sinceMouseUp: 0.3, sinceClipboardChange: 0.02), .wait)
        XCTAssertEqual(settle.step(elapsed: 0.4, buttonsDown: false, sinceMouseUp: 0.4, sinceClipboardChange: 0.12), .proceed)
    }

    func testNeverWaitsForever() {
        XCTAssertEqual(settle.step(elapsed: 1.5, buttonsDown: true, sinceMouseUp: 0, sinceClipboardChange: 0), .proceed)
    }

    func testAnOverwriteBeforeThePasteIsReadIsUndone() {
        XCTAssertEqual(PastePolicy.overwriteStep(sinceSend: 0.02, reads: 0, rewrites: 0, isTerminal: true), .rewrite)
        XCTAssertEqual(PastePolicy.overwriteStep(sinceSend: 0.02, reads: 0, rewrites: 0, isTerminal: false), .rewrite)
        XCTAssertEqual(PastePolicy.overwriteStep(sinceSend: 0.02, reads: 0, rewrites: PastePolicy.maxRewrites, isTerminal: true), .leave,
                       "don't fight another writer forever")
    }

    func testASelectionCopiedRightAfterATerminalPasteDoesNotBecomeTheClipboard() {
        XCTAssertEqual(PastePolicy.overwriteStep(sinceSend: 0.2, reads: 2, rewrites: 0, isTerminal: true), .adopt)
        XCTAssertEqual(PastePolicy.overwriteStep(sinceSend: 0.2, reads: 2, rewrites: 0, isTerminal: false), .leave)
    }

    func testALaterCopyIsTheUsersOwn() {
        XCTAssertEqual(PastePolicy.overwriteStep(sinceSend: 1.5, reads: 2, rewrites: 0, isTerminal: true), .leave)
        XCTAssertEqual(PastePolicy.overwriteStep(sinceSend: 1.5, reads: 0, rewrites: 0, isTerminal: true), .leave)
    }

    func testTheClipboardFromBeforeTheClickIsTheOneRestored() {
        // Unchanged since the first mouse-down: same thing either way.
        XCTAssertTrue(PastePolicy.useRememberedClipboard(rememberedCount: 7, currentCount: 7, age: 30))
        // Changed during the double-click: that was copy-on-select.
        XCTAssertTrue(PastePolicy.useRememberedClipboard(rememberedCount: 7, currentCount: 8, age: 0.3))
        // Changed long after the last click we saw: the user copied something.
        XCTAssertFalse(PastePolicy.useRememberedClipboard(rememberedCount: 7, currentCount: 8, age: 10))
        XCTAssertFalse(PastePolicy.useRememberedClipboard(rememberedCount: nil, currentCount: 8, age: nil))
    }

    func testACanvasDropGivesUpSooner() {
        let rules = PastePolicy.OutcomeRules(hasProbe: false, isCanvas: true)
        XCTAssertEqual(rules.evaluate(elapsed: 0.5, reads: 0, probeChanged: false), .pending)
        XCTAssertEqual(rules.evaluate(elapsed: 1.0, reads: 0, probeChanged: false), .failed)
        XCTAssertEqual(rules.evaluate(elapsed: 0.2, reads: 1, probeChanged: false), .accepted)
    }
}
