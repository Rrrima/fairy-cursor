/// Blends the sounds of a recording (the computer's, the microphone's) into one stereo track.
///
/// Each source hands in short pieces with the moment they belong to, counted in frames from the
/// start of the video. Pieces are added together where they overlap, and whatever nobody filled
/// is silence, so the track that comes out is continuous whatever the sources do.
public struct SoundMix {
    /// A piece that lands this close to where its source left off is joined to it exactly:
    /// timestamps wobble by a few frames, and a gap or overlap that small is a click.
    public static let snap = 960

    private var left: [Float] = []
    private var right: [Float] = []
    /// Frames already handed out; `left[0]` is this frame.
    public private(set) var base = 0
    /// Where each source's next piece is expected to start.
    private var expected: [Int: Int] = [:]

    public init() {}

    /// Add a piece from `source` starting at `frame`. Anything before what was already handed
    /// out is too late and is dropped.
    public mutating func add(source: Int, at frame: Int, left l: [Float], right r: [Float]) {
        let count = min(l.count, r.count)
        guard count > 0 else { return }
        var start = frame
        if let next = expected[source], abs(next - frame) <= Self.snap { start = next }
        expected[source] = start + count

        let skip = max(0, base - start)
        guard skip < count else { return }
        let end = start + count - base
        if left.count < end {
            left.append(contentsOf: repeatElement(0, count: end - left.count))
            right.append(contentsOf: repeatElement(0, count: end - right.count))
        }
        let offset = start - base
        for i in skip..<count {
            left[offset + i] += l[i]
            right[offset + i] += r[i]
        }
    }

    /// The next stretch of the track, up to (not including) `frame` and at most `limit` frames:
    /// where it starts, and its samples as left, right, left, right… Nil when there is nothing new.
    public mutating func drain(upTo frame: Int, limit: Int) -> (start: Int, samples: [Float])? {
        let count = min(frame - base, limit)
        guard count > 0 else { return nil }
        var out = [Float](repeating: 0, count: count * 2)
        let have = min(count, left.count)
        for i in 0..<have {
            // Two loud sources can add up past full scale; clip rather than wrap.
            out[i * 2] = max(-1, min(1, left[i]))
            out[i * 2 + 1] = max(-1, min(1, right[i]))
        }
        left.removeFirst(have)
        right.removeFirst(have)
        let start = base
        base += count
        return (start, out)
    }

    /// After a pause, or when the sources change, the next pieces start somewhere new: don't
    /// join them to where the old ones stopped.
    public mutating func breakContinuity() {
        expected.removeAll()
    }
}
