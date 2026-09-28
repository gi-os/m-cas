import XCTest
@testable import MCas

final class PressTests: XCTestCase {
    func testQuickPressIsATap() {
        var p = Press()
        XCTAssertNil(p.down(at: 0, recording: false))
        XCTAssertNil(p.tick(at: 0.2))
        XCTAssertEqual(p.up(at: 0.3), .tap)
    }

    func testHoldStartsRecordingOnceAndReleaseDoesNothing() {
        var p = Press()
        _ = p.down(at: 0, recording: false)
        XCTAssertNil(p.tick(at: 0.39))
        XCTAssertEqual(p.tick(at: 0.4), .holdStart)
        XCTAssertNil(p.tick(at: 0.6))
        XCTAssertNil(p.up(at: 1))
    }

    func testPressWhileRecordingStopsOnTheWayDown() {
        var p = Press()
        XCTAssertEqual(p.down(at: 0, recording: true), .stopRecording)
        XCTAssertNil(p.tick(at: 1))
        XCTAssertNil(p.up(at: 1.1))
    }

    func testDragCancelsThePress() {
        var p = Press()
        _ = p.down(at: 0, recording: false)
        p.cancel()
        XCTAssertNil(p.tick(at: 1))
        XCTAssertNil(p.up(at: 0.1))
    }
}
