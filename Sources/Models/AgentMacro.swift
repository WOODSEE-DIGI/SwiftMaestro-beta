import Foundation

// MARK: - Agent Macro

/// A user-defined (or built-in) one-click action for an agent. Macros appear as
/// buttons in the right-side panel and, when triggered, inject a configured
/// prompt into the agent's input and send it.
struct AgentMacro: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var icon: String
    /// The prompt text that is sent to the agent when the macro is clicked.
    var prompt: String
    /// Which agent kinds this macro is visible for. Empty means all agents.
    var agentKinds: [AgentKind]
    /// Whether this macro is shipped with the app and cannot be deleted.
    var isBuiltIn: Bool = false
    /// Optional tint color name (matches SwiftUI color names). Nil uses accent.
    var colorName: String?

    init(
        id: UUID = UUID(),
        title: String,
        icon: String,
        prompt: String,
        agentKinds: [AgentKind] = [],
        isBuiltIn: Bool = false,
        colorName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.prompt = prompt
        self.agentKinds = agentKinds
        self.isBuiltIn = isBuiltIn
        self.colorName = colorName
    }
}

// MARK: - Built-in macros

extension AgentMacro {
    /// Macros shipped with the app. These are re-added on every launch if missing
    /// so the user always has the core one-click workflows available.
    static var builtInMacros: [AgentMacro] {
        [
            AgentMacro(
                id: builtInCompactID,
                title: "Save Progress & Compact",
                icon: "arrow.down.right.and.arrow.up.left",
                prompt: "Save progress and compact the chat history.",
                agentKinds: [.coder, .onlineCoder, .navigator, .swiftHelper, .project, .search],
                isBuiltIn: true,
                colorName: "blue"
            ),
            AgentMacro(
                id: builtInReleasePipelineID,
                title: "Release Pipeline",
                icon: "shippingbox.fill",
                prompt: """
                Run the full SwiftMaestro release pipeline for the current version:
                1. Read RELEASE.md to confirm the exact runbook and required version/build numbers.
                2. Ask me for the CFBundleShortVersionString and CFBundleVersion if I have not already provided them.
                3. Run ./scripts/gen-project.sh and then xcodebuild build to verify the project compiles.
                4. Run ./scripts/release.sh (with UPLOAD=1 when I confirm). Report each milestone.
                5. Do not tag the release until the upload succeeds.
                """,
                agentKinds: [.coder, .onlineCoder, .swiftHelper],
                isBuiltIn: true,
                colorName: "green"
            )
        ]
    }

    static let builtInCompactID = UUID(uuidString: "A1B2C3D4-E5F6-7890-1234-567890ABCDEF")!
    static let builtInReleasePipelineID = UUID(uuidString: "B2C3D4E5-F6A7-8901-2345-678901BCDEF0")!
}
