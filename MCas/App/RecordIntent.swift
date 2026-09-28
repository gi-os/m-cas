import AppIntents

/// Bind this to the Action Button: press to start recording, press again to stop.
struct RecordMomentIntent: AppIntent {
    static var title: LocalizedStringResource = "Record a moment"
    static var description = IntentDescription("Start or stop recording onto the tape that is on the machine.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            Machine.shared.start()
            Machine.shared.toggleRecording()
        }
        return .result()
    }
}

struct MCasShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: RecordMomentIntent(), phrases: ["Record a moment with \(.applicationName)"], shortTitle: "Record a moment", systemImageName: "recordingtape")
    }
}
