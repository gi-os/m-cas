import Foundation

/// The rate a hand on the reel contributes while it is turning.
///
/// Ported from BrightRecorder. On the LP3 a notch was a key event from the brightness wheel;
/// here a notch is a few points of drag on the cassette. Each notch is worth a fixed length of
/// tape, so turning twice as fast covers twice as much: a hard spin reaches 8x, an unhurried
/// turn sits near 1.2x. It never changes the transport. It overrides the tape speed while the
/// hand is moving and then gives the tape back, so a slow steady turn must never drop to a
/// standstill between notches — that was the stutter bug on the phone.
struct Scrub {
    static let secondsPerNotch = 0.14
    static let minRate = 1.2
    static let maxRate = 8.0

    private(set) var lastNotch: Double?
    private(set) var interval: Double = 0.2
    private(set) var direction = 0

    mutating func notch(_ dir: Int, at t: Double) {
        let d = dir >= 0 ? 1 : -1
        if let last = lastNotch, d == direction {
            let gap = min(0.5, max(0.008, t - last))
            interval = interval * 0.5 + gap * 0.5
        } else {
            interval = 0.2
        }
        direction = d
        lastNotch = t
    }

    /// Nil once the hand has let go of the reel.
    func rate(at t: Double) -> Double? {
        guard let last = lastNotch else { return nil }
        let window = max(0.25, interval * 2.2)
        guard t - last <= window else { return nil }
        let speed = min(Self.maxRate, max(Self.minRate, Self.secondsPerNotch / interval))
        return Double(direction) * speed
    }

    mutating func reset() { lastNotch = nil; direction = 0; interval = 0.2 }
}
