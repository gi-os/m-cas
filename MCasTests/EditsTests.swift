import XCTest
@testable import MCas

final class EditsTests: XCTestCase {
    private func clip(_ i: Int, _ secs: Double, trimIn: Double = 0, trimOut: Double? = nil, at: Double? = nil) -> Timeline.Clip {
        Timeline.Clip(url: URL(fileURLWithPath: "/\(i).wav"), seconds: secs, date: Date(timeIntervalSince1970: Double(i)), name: "c\(i)",
                      trimIn: trimIn, trimOut: trimOut, overdubAt: at)
    }

    func testTrimsShortenTheTape() {
        let t = Timeline(clips: [clip(0, 10, trimIn: 2, trimOut: 8), clip(1, 5)])
        XCTAssertEqual(t.total, 11, accuracy: 1e-9)
        let a = t.locate(0)!
        XCTAssertEqual(a.index, 0); XCTAssertEqual(a.offset, 2, accuracy: 1e-9)
        let b = t.locate(6)!
        XCTAssertEqual(b.index, 1); XCTAssertEqual(b.offset, 0, accuracy: 1e-9)
    }

    func testTakeCoversTheMiddleOfAClip() {
        // 20 s clip, a 5 s take recorded at 8 s.
        let t = Timeline(clips: [clip(0, 20), clip(1, 5, at: 8)])
        XCTAssertEqual(t.total, 20, accuracy: 1e-9)
        XCTAssertEqual(t.segments.count, 3)
        XCTAssertEqual(t.locate(7.9)!.index, 0)
        let mid = t.locate(10)!
        XCTAssertEqual(mid.index, 1); XCTAssertEqual(mid.offset, 2, accuracy: 1e-9)
        let after = t.locate(14)!
        XCTAssertEqual(after.index, 0); XCTAssertEqual(after.offset, 14, accuracy: 1e-9)
        XCTAssertTrue(t.covered(9)); XCTAssertFalse(t.covered(15))
        // The original is still whole in the layers.
        XCTAssertEqual(t.layers.first { $0.clip == 0 }!.length, 20, accuracy: 1e-9)
    }

    func testTakeRunningPastTheEndLengthensTheTape() {
        let t = Timeline(clips: [clip(0, 10), clip(1, 6, at: 7)])
        XCTAssertEqual(t.total, 13, accuracy: 1e-9)
        XCTAssertEqual(t.locate(12)!.index, 1)
    }

    func testLaterTakeWins() {
        let t = Timeline(clips: [clip(0, 30), clip(1, 10, at: 5), clip(2, 4, at: 8)])
        XCTAssertEqual(t.locate(9)!.index, 2)
        XCTAssertEqual(t.locate(13)!.index, 1)
        XCTAssertEqual(t.locate(20)!.index, 0)
    }

    func testTakeSpanningTwoClips() {
        let t = Timeline(clips: [clip(0, 10), clip(1, 10), clip(2, 6, at: 7)])
        XCTAssertEqual(t.locate(8)!.index, 2)
        XCTAssertEqual(t.locate(14)!.index, 1)
        XCTAssertEqual(t.locate(14)!.offset, 4, accuracy: 1e-9)
    }

    func testEditsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("e-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var e = Edits()
        e.trims["2026-09-28 191200"] = .init(trimIn: 1.5, trimOut: 9)
        e.takes["2026-09-28 193000"] = 4
        e.save(dir)
        XCTAssertEqual(Edits.load(dir), e)
        let c = Timeline.Clip(url: dir.appendingPathComponent("2026-09-28 193000 Bar.wav"), seconds: 5, date: Date(), name: "Bar")
        XCTAssertEqual(e.apply(to: c).overdubAt, 4)
    }
}
