import SwiftUI

enum SwiftMaestroDefaultsMigration {
    static func applyIfNeeded() {
        let defaults = UserDefaults.standard
        let modelKey = "models.modelID"
        let modelMigrationKey = "migration.defaultModel.v2"
        let targetModel = ModelTierPolicy.defaultModelID

        let currentModel = defaults.string(forKey: modelKey)
        if currentModel == nil || currentModel?.isEmpty == true {
            defaults.set(targetModel, forKey: modelKey)
        } else if currentModel == ModelTierPolicy.legacyDefaultModelID,
                  !defaults.bool(forKey: modelMigrationKey) {
            // One-time: move installs off the old auto-set 122B default (which
            // preloaded a 65GB model every launch) to the fast MoE default.
            // Gated by a flag so a later deliberate 122B choice is never clobbered.
            defaults.set(targetModel, forKey: modelKey)
        }
        defaults.set(true, forKey: modelMigrationKey)
    }
}

@main
struct SwiftMaestroApp: App {
    @State private var engine = MLXInferenceEngine()
    @State private var catalog = ModelCatalog()
    @State private var workspace = WorkspaceStore()
    @State private var todoStore = TodoStore()
    @State private var planStore = PlanStore()
    @State private var messageStore = AgentMessageStore()
    private let mcpService = MCPClientService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .environment(catalog)
                .environment(workspace)
                .environment(todoStore)
                .environment(planStore)
                .environment(messageStore)
                .task {
                    SwiftMaestroDefaultsMigration.applyIfNeeded()
                    // Expose the workspace to native delegation/workspace tools.
                    MaestroTools.workspace = workspace
                    // Expose the live-todo store to the native todo tools.
                    MaestroTools.todoStore = todoStore
                    // Expose the plan store to the native plan tools.
                    MaestroTools.planStore = planStore
                    // Expose the inter-agent message store to the messaging tools.
                    MaestroTools.messageStore = messageStore
                    // Wire client-side MCP tools into the inference engine and
                    // spawn the user-enabled servers (permissioned by MCP flags).
                    engine.mcpService = mcpService
                    await mcpService.startEnabledServers()
                }
        }
        .defaultSize(width: 1100, height: 760)

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
                .environment(catalog)
                .environment(workspace)
                .environment(todoStore)
                .environment(planStore)
                .environment(messageStore)
        }
        .defaultSize(width: 720, height: 760)
        #endif
    }
}
