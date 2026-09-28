import Foundation

/// A tape, laid out end to end, with edits.
///
/// Every clip is a whole WAV file that is never changed. Edits live beside the files:
/// - a trim (`trimIn`, `trimOut`) says which part of a clip is on the tape;
/// - a take recorded over the tape (`overdubAt`) sits at a tape position and covers
///   whatever was there, the way recording over a cassette does.
///
/// `segments` is what you hear: the base clips butted end to end (BrightRecorder's
/// continuous tape), with each take cut in on top, later takes over earlier ones. Covered
/// audio isn't gone; it's just not in `segments`. `layers` keeps everything, for the editor.
struct Timeline: Equatable {
    struct Clip: Equatable {
        var url: URL
        var seconds: Double           // length of the whole file
        var date: Date
        var name: String
        var trimIn: Double = 0
        var trimOut: Double? = nil    // nil: to the end of the file
        var overdubAt: Double? = nil  // nil: part of the base tape

        var outPoint: Double { min(seconds, max(trimIn, trimOut ?? seconds)) }
        var length: Double { max(0, outPoint - trimIn) }
        var isTake: Bool { overdubAt != nil }
    }

    /// A stretch of tape: `length` seconds starting at tape position `start`, read from
    /// clip `clip` starting at `src` seconds into its file.
    struct Segment: Equatable {
        var clip: Int
        var src: Double
        var start: Double
        var length: Double
        var end: Double { start + length }
    }

    let clips: [Clip]
    /// What plays, in order, never overlapping.
    let segments: [Segment]
    /// Every clip where it sits on the tape before anything covers it: base clips first,
    /// then each take. For the layers view and for trimming.
    let layers: [Segment]
    let total: Double

    init(clips: [Clip]) {
        self.clips = clips
        var layers: [Segment] = []
        var t = 0.0
        for (i, c) in clips.enumerated() where !c.isTake && c.length > 0 {
            layers.append(Segment(clip: i, src: c.trimIn, start: t, length: c.length))
            t += c.length
        }
        var segs = layers
        // Takes in recording order: a later take covers an earlier one.
        let takes = clips.enumerated().filter { $0.element.isTake && $0.element.length > 0 }
            .sorted { $0.element.date < $1.element.date }
        for (i, c) in takes {
            let take = Segment(clip: i, src: c.trimIn, start: max(0, c.overdubAt ?? 0), length: c.length)
            layers.append(take)
            segs = Timeline.cover(segs, with: take)
        }
        segs.sort { $0.start < $1.start }
        segments = segs
        self.layers = layers
        total = segs.map(\.end).max() ?? 0
    }

    /// `segs` with `take` cut in: anything it overlaps is trimmed or split around it.
    static func cover(_ segs: [Segment], with take: Segment) -> [Segment] {
        var out: [Segment] = []
        for s in segs {
            if s.end <= take.start || s.start >= take.end { out.append(s); continue }
            if s.start < take.start {
                out.append(Segment(clip: s.clip, src: s.src, start: s.start, length: take.start - s.start))
            }
            if s.end > take.end {
                let cut = take.end - s.start
                out.append(Segment(clip: s.clip, src: s.src + cut, start: take.end, length: s.end - take.end))
            }
        }
        out.append(take)
        return out
    }

    var isEmpty: Bool { segments.isEmpty || total <= 0 }

    /// Where each segment starts on the tape.
    var starts: [Double] { segments.map(\.start) }

    /// The segment a tape position falls in, if any (a take recorded past the end can leave
    /// a gap of silence).
    func segmentIndex(at t: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        let p = min(max(t, 0), total)
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].start <= p { lo = mid } else { hi = mid - 1 }
        }
        let s = segments[lo]
        if p >= s.start && p <= s.end { return lo }
        return nil
    }

    /// The clip playing at a tape position and how far into its file. Clamped to the tape.
    func locate(_ t: Double) -> (index: Int, offset: Double)? {
        guard !isEmpty, let i = segmentIndex(at: t) else { return nil }
        let s = segments[i]
        let p = min(max(t, 0), total)
        return (s.clip, s.src + min(p - s.start, s.length))
    }

    func clipIndex(at t: Double) -> Int? { locate(t)?.index }

    /// Start of segment `index` on the tape.
    func start(of index: Int) -> Double { segments.indices.contains(index) ? segments[index].start : 0 }

    func fraction(_ t: Double) -> Double { total > 0 ? min(max(t / total, 0), 1) : 0 }

    /// Is this tape position covered by a take (so the base audio there is hidden)?
    func covered(_ t: Double) -> Bool {
        layers.contains { clips[$0.clip].isTake && t >= $0.start && t < $0.end }
    }
}
