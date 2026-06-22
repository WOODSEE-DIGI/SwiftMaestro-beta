import SwiftUI

enum SwiftMaestroDefaultsMigration {
    static func applyIfNeeded() {
        let defaults = UserDefaults.standard
        // The catalog reads this exact key. The previous migration wrote a
        // DIFFERENT, unread key (`models.modelID`) using a Hub name instead of a
        // catalog id, so it never actually took effect.
        let modelKey = "models.selectedModelID"
        let modelMigrationKey = "migration.defaultModel.v3"
        let targetModel = ModelCatalog.defaultModelID
        let legacyDefault = "local-qwen3.5-122b"

        let currentModel = defaults.string(forKey: modelKey)
        if currentModel == nil || currentModel?.isEmpty == true {
            defaults.set(targetModel, forKey: modelKey)
        } else if currentModel == legacyDefault,
                  !defaults.bool(forKey: modelMigrationKey) {
            // One-time: move installs off the old 65GB 122B default (which
            // preloaded a huge model every launch) to the fast MoE default.
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
    @State private var theme = ThemeStore()
    @State private var whisperService = WhisperKitService()
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
                .environment(theme)
                .environment(whisperService)
                .task {
                    SwiftMaestroDefaultsMigration.applyIfNeeded()
                    // Create the shared ~/.ai-context scaffold up front so a fresh,
                    // self-contained install has its data directory before first use.
                    SimpleMemoryStore.ensureScaffold()
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
                    // Eagerly load the default model at startup so the first
                    // message doesn't block on model init/download.
                    if let model = catalog.selectedModel {
                        Task.detached(priority: .userInitiated) {
                            _ = try? await engine.loadModel(model)
                        }
                    }
                    // Eagerly load WhisperKit so the mic button is ready.
                    whisperService.ensureModelLoaded()
                }
        }
        .defaultSize(width: 1100, height: 760)

        // Standalone, resizable reading window for a single plan. Data-driven so
        // `openWindow(id:value:)` from the Plans browser opens (or fronts) the
        // window for a specific plan. `.contentSize` resizability lets the plan's
        // own ideal size drive the opening dimensions (clamped to the screen).
        WindowGroup("Plan", id: "plan-window", for: PlanWindowID.self) { $target in
            PlanWindowView(target: target)
                .environment(planStore)
                .environment(theme)
        }
        .windowResizability(.contentSize)

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
                .environment(catalog)
                .environment(workspace)
                .environment(todoStore)
                .environment(planStore)
                .environment(messageStore)
                .environment(theme)
                .environment(whisperService)
        }
        .defaultSize(width: 760, height: 820)
        // Settings scenes default to `.contentSize`, which pins the window to the
        // content's size (so it can't be resized). `.contentMinSize` enforces only
        // the content's MINIMUM, letting the user resize the window larger to use
        // available screen space (e.g. see the Appearance preview without scrolling).
        .windowResizability(.contentMinSize)
        #endif
    }
}
