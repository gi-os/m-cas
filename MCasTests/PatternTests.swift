import XCTest
@testable import MCas

final class PatternTests: XCTestCase {
    /// Must match Java's String.hashCode so a tape folder looks the same on both phones.
    func testJavaHash() {
        XCTAssertEqual(Pattern.javaHash("hello"), 99162322)
        XCTAssertEqual(Pattern.javaHash(""), 0)
        XCTAssertEqual(Pattern.javaHash("Trip to Rome"), Pattern.javaHash("Trip to Rome"))
    }

    func testDerivedIsStableAndNeverPhoto() {
        for n in ["Trip to Rome", "The apt", "2026", "Basil noises", "x"] {
            XCTAssertEqual(Pattern.derived(from: n), Pattern.derived(from: n))
            XCTAssertNotEqual(Pattern.derived(from: n), .photo)
        }
    }

    func testLabelLine() {
        XCTAssertEqual(LabelSpec(line: "spots 3\n"), LabelSpec(pattern: .spots, pair: 3))
        XCTAssertEqual(LabelSpec(pattern: .waves, pair: 9).pair, 5)
        XCTAssertNil(LabelSpec(line: "plaid"))
        XCTAssertEqual(LabelSpec(line: "BANDS")?.pattern, .bands)
    }
}
