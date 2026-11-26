import XCTest
@testable import FairyCore

final class SoundMixTests: XCTestCase {
    private func piece(_ value: Float, _ count: Int) -> [Float] { [Float](repeating: value, count: count) }

    func testTwoSourcesAddUp() {
        var mix = SoundMix()
        mix.add(source: 0, at: 0, left: piece(0.25, 4), right: piece(0.25, 4))
        mix.add(source: 1, at: 2, left: piece(0.5, 4), right: piece(0.1, 4))
        let out = mix.drain(upTo: 6, limit: 100)
        XCTAssertEqual(out?.start, 0)
        XCTAssertEqual(out?.samples, [0.25, 0.25, 0.25, 0.25, 0.75, 0.35, 0.75, 0.35, 0.5, 0.1, 0.5, 0.1])
    }

    func testNothingIsSilence() {
        var mix = SoundMix()
        let out = mix.drain(upTo: 3, limit: 100)
        XCTAssertEqual(out?.samples, piece(0, 6))
        XCTAssertEqual(mix.base, 3)
        XCTAssertNil(mix.drain(upTo: 3, limit: 100))
    }

    func testDrainIsLimitedAndContinues() {
        var mix = SoundMix()
        mix.add(source: 0, at: 0, left: [1, 2, 3, 4].map { $0 / 10 }, right: [1, 2, 3, 4].map { $0 / 10 })
        XCTAssertEqual(mix.drain(upTo: 4, limit: 3)?.samples.count, 6)
        let rest = mix.drain(upTo: 4, limit: 3)
        XCTAssertEqual(rest?.start, 3)
        XCTAssertEqual(rest?.samples, [0.4, 0.4])
    }

    func testLoudSourcesClip() {
        var mix = SoundMix()
        mix.add(source: 0, at: 0, left: piece(0.8, 1), right: piece(-0.8, 1))
        mix.add(source: 1, at: 0, left: piece(0.8, 1), right: piece(-0.8, 1))
        XCTAssertEqual(mix.drain(upTo: 1, limit: 10)?.samples, [1, -1])
    }

    func testLatePieceIsDropped() {
        var mix = SoundMix()
        _ = mix.drain(upTo: 10, limit: 100)
        // Starts 2 frames before what was handed out: only its last 2 frames still count.
        mix.add(source: 0, at: 8, left: piece(0.5, 4), right: piece(0.5, 4))
        XCTAssertEqual(mix.drain(upTo: 12, limit: 100)?.samples, piece(0.5, 4))
    }

    func testWobblyTimestampsJoinExactly() {
        var mix = SoundMix()
        mix.add(source: 0, at: 0, left: piece(0.5, 100), right: piece(0.5, 100))
        // Says 103, but the source left off at 100: no 3-frame hole.
        mix.add(source: 0, at: 103, left: piece(0.5, 100), right: piece(0.5, 100))
        let out = mix.drain(upTo: 200, limit: 1000)
        XCTAssertEqual(out?.samples, piece(0.5, 400))
    }

    func testAfterABreakPiecesGoWhereTheySay() {
        var mix = SoundMix()
        mix.add(source: 0, at: 0, left: piece(0.5, 100), right: piece(0.5, 100))
        mix.breakContinuity()
        mix.add(source: 0, at: 103, left: piece(0.5, 1), right: piece(0.5, 1))
        let out = mix.drain(upTo: 104, limit: 1000)!
        XCTAssertEqual(out.samples[200], 0)
        XCTAssertEqual(out.samples[206], 0.5)
    }
}
