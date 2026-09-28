import XCTest
@testable import MCas

final class WavTests: XCTestCase {
    private func wav(frames: [Int16], rate: UInt32 = 48000, filler: Bool = false, lie: UInt32? = nil) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(0); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        if filler { d.append(contentsOf: Array("FLLR".utf8)); u32(6); d.append(contentsOf: [0, 0, 0, 0, 0, 0]) }
        d.append(contentsOf: Array("data".utf8)); u32(lie ?? UInt32(frames.count * 2))
        for f in frames { withUnsafeBytes(of: f.littleEndian) { d.append(contentsOf: $0) } }
        return d
    }

    func testParsesPlainHeader() {
        let d = wav(frames: Array(repeating: 0, count: 480))
        let h = d.withUnsafeBytes { WavHeader.parse($0) }!
        XCTAssertEqual(h.sampleRate, 48000)
        XCTAssertEqual(h.frames, 480)
        XCTAssertEqual(h.seconds, 0.01, accuracy: 1e-9)
    }

    func testSkipsFillerChunk() {
        let d = wav(frames: [1, 2, 3], filler: true)
        let h = d.withUnsafeBytes { WavHeader.parse($0) }!
        XCTAssertEqual(h.frames, 3)
    }

    func testCutOffRecordingTrustsTheFile() {
        let d = wav(frames: Array(repeating: 0, count: 100), lie: 0)
        let h = d.withUnsafeBytes { WavHeader.parse($0) }!
        XCTAssertEqual(h.frames, 100)
    }

    func testMappedSamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).wav")
        try wav(frames: [0, 16384, -16384, 0], rate: 4).write(to: url)
        let m = try XCTUnwrap(MappedWav(url: url))
        XCTAssertEqual(m.seconds, 1, accuracy: 1e-9)
        XCTAssertEqual(m.sample(at: 0.25), 0.5, accuracy: 1e-4)
        XCTAssertEqual(m.sample(at: 0.5), -0.5, accuracy: 1e-4)
        XCTAssertEqual(m.sample(at: 0.375), 0, accuracy: 1e-4)
        XCTAssertEqual(m.sample(at: 5), 0)
    }
}
