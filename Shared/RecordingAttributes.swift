import ActivityKit
import AppIntents
import Foundation

/// The Live Activity while m-cas is recording: in the Dynamic Island and on the Lock Screen.
struct RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var place: String
        var started: Date
    }
    var tape: String
}

/// The Stop button on the Live Activity. Runs in the app.
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
