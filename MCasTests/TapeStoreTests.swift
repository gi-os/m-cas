import XCTest
@testable import MCas

final class TapeStoreTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("tapes-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testCreateListRename() {
        let s = TapeStore(root: root)
        let t = s.create(name: "Trip to Rome")
        XCTAssertEqual(s.tapes().map(\.name), ["Trip to Rome"])
        let r = s.rename(t, to: "Rome 2026")
        XCTAssertEqual(s.tapes().map(\.name), ["Rome 2026"])
        XCTAssertEqual(Naming.parse(r.url.lastPathComponent)?.date, Naming.parse(t.url.lastPathComponent)?.date)
    }

    func testLabelPersists() {
        let s = TapeStore(root: root)
        let t = s.create(name: "The apt")
        s.writeLabel(t.url, LabelSpec(pattern: .checks, pair: 4))
        XCTAssertEqual(s.tapes().first?.label, LabelSpec(pattern: .checks, pair: 4))
    }

    func testRefusesToDeleteATapeWithClips() throws {
        let s = TapeStore(root: root)
        let t = s.create(name: "Keep")
        var d = Data("RIFF\0\0\0\0WAVEfmt ".utf8)
        d.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0xBB, 0, 0, 0, 0x77, 1, 0, 2, 0, 16, 0])
        d.append(contentsOf: Array("data".utf8)); d.append(contentsOf: [0, 0x2C, 1, 0]) // 76800 bytes = 0.8 s
        d.append(Data(count: 76800))
        try d.write(to: s.newClipURL(in: t))
        XCTAssertEqual(s.clips(in: t).count, 1)
        XCTAssertFalse(s.delete(t))
        XCTAssertEqual(s.tapes().count, 1)
    }
}
