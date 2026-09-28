import ActivityKit
import AppIntents
import Foundation

/// The Live Activity while m-cas records: Dynamic Island and Lock Screen. It stays a few
/// seconds after you stop, as a "saved" card.
struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var place: String
        var started: Date
        var saved = false
        var seconds: Double = 0
    }
    var tape: String
    var clip: Int
    /// The tape's label colors as hex, so the little cassette matches the one on the shelf.
    var labelA: String
    var labelB: String
}

/// The Stop key on the Live Activity. Runs in the app.
struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop recording"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        #if MCAS_APP
        await MainActor.run { Machine.shared.stopRecording() }
        #endif
        return .result()
    }
}
