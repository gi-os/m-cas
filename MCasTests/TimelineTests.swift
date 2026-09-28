import XCTest
@testable import MCas

final class TimelineTests: XCTestCase {
    private func tl(_ secs: [Double]) -> Timeline {
        Timeline(clips: secs.enumerated().map { .init(url: URL(fileURLWithPath: "/\($0.offset).wav"), seconds: $0.element, date: Date(), name: "c\($0.offset)") })
    }

    func testEmpty() {
        XCTAssertNil(tl([]).locate(0))
        XCTAssertEqual(tl([]).total, 0)
    }

    func testTotalAndStarts() {
        let t = tl([10, 5, 20])
        XCTAssertEqual(t.total, 35)
        XCTAssertEqual(t.starts, [0, 10, 15])
    }

    func testPlayingOffTheEndOfAClipRunsIntoTheNext() {
        let t = tl([10, 5, 20])
        XCTAssertEqual(t.locate(9.99)?.index, 0)
        XCTAssertEqual(t.locate(10)?.index, 1)
        XCTAssertEqual(t.locate(10)!.offset, 0, accuracy: 1e-9)
        XCTAssertEqual(t.locate(15.5)!.index, 2)
        XCTAssertEqual(t.locate(15.5)!.offset, 0.5, accuracy: 1e-9)
    }

    func testClampsToTheTape() {
        let t = tl([10, 5])
        XCTAssertEqual(t.locate(-3)?.index, 0)
        XCTAssertEqual(t.locate(-3)!.offset, 0, accuracy: 1e-9)
        XCTAssertEqual(t.locate(99)?.index, 1)
        XCTAssertEqual(t.locate(99)!.offset, 5, accuracy: 1e-9)
    }

    func testFraction() {
        let t = tl([10, 10])
        XCTAssertEqual(t.fraction(5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(t.fraction(50), 1, accuracy: 1e-9)
    }
}
