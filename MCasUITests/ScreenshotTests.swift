import XCTest

/// App Store screenshots of the demo tapes, one launch per screen (the pixel screen is a
/// single canvas, so screens are opened by launch argument rather than by tapping).
final class ScreenshotTests: XCTestCase {
    @MainActor private func shot(_ name: String, _ extra: [String]) {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-demo"] + extra
        app.launch()
        sleep(4)
        snapshot(name)
        app.terminate()
    }

    @MainActor func testScreenshots() {
        continueAfterFailure = true
        shot("01-Deck", ["-screen", "deck"])
        shot("02-Tape", ["-screen", "deck", "-flipped"])
        shot("03-Edit", ["-screen", "edit", "-layers"])
        shot("04-Clips", ["-screen", "clips"])
        shot("05-Shelf", ["-screen", "shelf"])
    }
}
