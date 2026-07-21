import Foundation
import AppIntents

/// Siri/App Intents shortcut: ask the SwiftMaestro agent a question hands-free.
///
/// Usage: "Hey Siri, ask SwiftMaestro agent what is the weather in Sydney?"
struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask SwiftMaestro agent"
    static let description: IntentDescription = IntentDescription(
        "Send a question to the active SwiftMaestro agent",
        categoryName: "SwiftMaestro"
    )

    /// Ask Siri to bring the app to the foreground so the response is visible.
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What would you like to ask the agent?"))
    var question: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        await AgentCommandCenter.shared.askAgent(question: question)
        return .result(value: "Sent to SwiftMaestro agent: \(question)")
    }
}

/// Optional extra intent for hands-free recording control.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start recording in SwiftMaestro"
    static let description: IntentDescription = IntentDescription(
        "Begin a WhisperKit voice recording",
        categoryName: "SwiftMaestro"
    )

    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            // We cannot easily reach the environment WhisperKitService from an
            // intent, so post a notification that the UI observes.
            NotificationCenter.default.post(name: .startWhisperRecording, object: nil)
        }
        return .result()
    }
}

extension Notification.Name {
    static let startWhisperRecording = Notification.Name("com.woodseedigi.swiftmaestro.startWhisperRecording")
}
