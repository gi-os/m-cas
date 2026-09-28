import XCTest
@testable import MCas

final class NamingTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let date = Date(timeIntervalSince1970: 1_786_977_552) // 2026-08-17 14:39:12 UTC

    func testClipFileName() {
        XCTAssertEqual(Naming.clipFile(date: date, place: "Trastevere, Rome", tz: utc), "2026-08-17 143912 Trastevere, Rome.wav")
    }

    func testRoundTrip() {
        let p = Naming.parse("2026-08-17 143912 Trastevere, Rome.wav", tz: utc)
        XCTAssertEqual(p?.label, "Trastevere, Rome")
        XCTAssertEqual(p?.date, date)
    }

    func testSlashesCannotMakeFolders() {
        XCTAssertEqual(Naming.clean("AC/DC: live"), "AC-DC- live")
        XCTAssertEqual(Naming.clean("   "), Naming.fallbackPlace)
    }

    func testNotOurFile() {
        XCTAssertNil(Naming.parse("holiday.wav"))
    }

    func testShort() {
        XCTAssertEqual(Naming.short(date, tz: utc), "AUG 17 14:39")
    }
}
