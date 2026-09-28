import Foundation

/// Every clip on a tape, butted end to end and addressed as one continuous tape.
///
/// A position is seconds from the first sample of the first clip. Playing off the end of a
/// clip runs into the next; winding back past the start of one lands in the one before.
/// There is no "next track" anywhere in the app — the end of a clip is a position like any other.
struct Timeline: Equatable {
    struct Clip: Equatable {
        var url: URL
        var seconds: Double
        var date: Date
        var name: String
    }

    let clips: [Clip]
    /// Where each clip starts on the tape.
    let starts: [Double]
    let total: Double

    init(clips: [Clip]) {
        self.clips = clips
        var acc = 0.0
        var s: [Double] = []
        for c in clips { s.append(acc); acc += max(0, c.seconds) }
        starts = s
        total = acc
    }

    var isEmpty: Bool { clips.isEmpty || total <= 0 }

    /// The clip a tape position falls in, and how far into it. Clamped to the tape.
    func locate(_ t: Double) -> (index: Int, offset: Double)? {
        guard !isEmpty else { return nil }
        let p = min(max(t, 0), total)
        var lo = 0, hi = clips.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= p { lo = mid } else { hi = mid - 1 }
        }
        // A zero-length clip at the end should not swallow the final position.
        return (lo, min(p - starts[lo], clips[lo].seconds))
    }

    func clipIndex(at t: Double) -> Int? { locate(t)?.index }

    func start(of index: Int) -> Double { starts.indices.contains(index) ? starts[index] : 0 }

    /// Position as a fraction of the whole tape, for the reels and the tape bar.
    func fraction(_ t: Double) -> Double { total > 0 ? min(max(t / total, 0), 1) : 0 }
}
