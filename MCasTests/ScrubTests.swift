import XCTest
@testable import MCas

final class ScrubTests: XCTestCase {
    func testNoHandNoRate() { XCTAssertNil(Scrub().rate(at: 0)) }

    /// The bug that shipped on the LP3: a slow steady turn must never drop the tape to a
    /// standstill between notches.
    func testSlowSteadyTurnNeverStallsBetweenNotches() {
        var s = Scrub()
        var t = 0.0
        for _ in 0..<20 {
            s.notch(1, at: t)
            for k in 1...9 { XCTAssertNotNil(s.rate(at: t + 0.2 * Double(k) / 10), "stalled at \(t)") }
            t += 0.2
        }
    }

    func testFasterTurnWindsFaster() {
        var slow = Scrub(), fast = Scrub()
        for i in 0..<10 { slow.notch(1, at: Double(i) * 0.2); fast.notch(1, at: Double(i) * 0.035) }
        XCTAssertGreaterThan(fast.rate(at: 9 * 0.035)!, slow.rate(at: 9 * 0.2)!)
        XCTAssertGreaterThanOrEqual(fast.rate(at: 9 * 0.035)!, 3.5)
    }

    func testRateIsClamped() {
        var s = Scrub()
        for i in 0..<30 { s.notch(1, at: Double(i) * 0.001) }
        XCTAssertEqual(s.rate(at: 0.029)!, Scrub.maxRate, accuracy: 1e-9)
        var slow = Scrub()
        slow.notch(1, at: 0); slow.notch(1, at: 0.5)
        XCTAssertGreaterThanOrEqual(slow.rate(at: 0.5)!, Scrub.minRate)
    }

    func testBackwardsIsNegative() {
        var s = Scrub()
        s.notch(-1, at: 0); s.notch(-1, at: 0.05)
        XCTAssertLessThan(s.rate(at: 0.05)!, 0)
    }

    func testLettingGoHandsTheTapeBack() {
        var s = Scrub()
        s.notch(1, at: 0)
        XCTAssertNil(s.rate(at: 2))
    }
}
