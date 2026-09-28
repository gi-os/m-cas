import Foundation

/// Tap to play or stop, hold to record — the decision, with no clock of its own.
///
/// Ported from BrightRecorder's wheel press. The caller supplies the times and calls `tick`
/// from its own timer, so every branch is testable. Four-tenths of a second is the line:
/// long enough that pressing play never records by accident. A press while recording stops
/// the recording on the way down, because stopping should happen the instant you ask.
struct Press {
    enum Event: Equatable { case tap, holdStart, stopRecording }

    static let holdThreshold = 0.4

    private(set) var downAt: Double?
    private(set) var held = false

    mutating func down(at t: Double, recording: Bool) -> Event? {
        if recording { downAt = nil; held = false; return .stopRecording }
        downAt = t
        held = false
        return nil
    }

    mutating func tick(at t: Double) -> Event? {
        guard let d = downAt, !held, t - d >= Self.holdThreshold else { return nil }
        held = true
        return .holdStart
    }

    mutating func up(at t: Double) -> Event? {
        defer { downAt = nil; held = false }
        guard let d = downAt, !held else { return nil }
        return t - d < Self.holdThreshold ? .tap : nil
    }

    /// The finger turned into a drag: it was never a press.
    mutating func cancel() { downAt = nil; held = false }
}
