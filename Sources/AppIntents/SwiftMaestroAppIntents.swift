import Foundation

extension Notification.Name {
    /// Posted by the (currently disabled) App Intents shortcut to start a voice
    /// recording. Kept outside the conditional so the in-app hotkey path remains
    /// valid if App Intents are re-enabled later.
    static let startWhisperRecording = Notification.Name("com.woodseedigi.swiftmaestro.startWhisperRecording")
}

#if ENABLE_APP_INTENTS
import AppIntents

/// Siri/App Intents shortcut: ask the SwiftMaestro agent a question hands-free.
///
/// Usage: "Hey Siri, ask SwiftMaestro what is the weather in Sydney?"
struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask SwiftMaestro"
    static let description: IntentDescription = IntentDescription(
        "Send a question to the Maestro agent in SwiftMaestro",
        categoryName: "SwiftMaestro"
    )

    /// Ask Siri to bring the app to the foreground so the response is visible.
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What would you like to ask?"))
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await AgentCommandCenter.shared.askAgent(question: question)
        return .result(value: "Sent to SwiftMaestro: \(question)")
    }
}

/// Optional extra intent for hands-free recording control.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording in SwiftMaestro"
    static let description: IntentDescription = IntentDescription(
        "Begin a WhisperKit voice recording in the Maestro chat",
        categoryName: "SwiftMaestro"
    )

    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .startWhisperRecording, object: nil)
        }
        return .result()
    }
}

/// Explicit Siri phrase suggestions so the system knows how to invoke the intents.
struct SwiftMaestroShortcutsProvider: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: [
                "Ask a question in \(.applicationName)",
                "Ask my \(.applicationName) agent",
                "Ask \(.applicationName)"
            ],
            shortTitle: "Ask SwiftMaestro",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Start a voice note in \(.applicationName)",
                "Record in \(.applicationName)"
            ],
            shortTitle: "Record in SwiftMaestro",
            systemImageName: "record.circle"
        )
    }
}

#endif
