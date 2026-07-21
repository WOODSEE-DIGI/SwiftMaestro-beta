import SwiftUI
import SwiftMaestroKit

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

/// Ensures spawned MCP server subprocesses are terminated when the app quits.
/// Without this, every successfully-connected MCP server subprocess is an
/// orphan the moment the app exits — nothing else references it once it's
/// no longer needed. (Servers that fail to connect in the first place are a
/// separate leak, fixed at the source in `MCPClientService.connect(to:)`.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var mcpService: MCPClientService?
    var whatsAppService: WhatsAppService?

    func applicationWillTerminate(_ notification: Notification) {
        if let mcpService {
            Task { await mcpService.shutdown() }
        }
        // The WhatsApp bridge is a long-running native process (holds the
        // live connection) - same leak risk as MCP servers if nothing stops
        // it on quit, so it gets the same cleanup treatment.
        whatsAppService?.stop()
    }
}

@main
struct SwiftMaestroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var engine = MLXInferenceEngine()
    @State private var catalog = ModelCatalog()
    @State private var workspace = WorkspaceStore()
    @State private var todoStore = TodoStore()
    @State private var planStore = PlanStore()
    @State private var messageStore = AgentMessageStore()
    @State private var theme: ThemeStore
    @State private var skinStore: SkinStore
    @State private var whisperService = WhisperKitService()

    init() {
        let theme = ThemeStore()
        _theme = State(wrappedValue: theme)
        _skinStore = State(wrappedValue: SkinStore(theme: theme))
    }
    @State private var visionProxyService = VisionProxyService()
    @State private var notesViewModel = NotesViewModel()
    @State private var eventKitStore = EventKitStore()
    @State private var appleNotesService = AppleNotesService()
    @State private var contactsService = ContactsService()
    @State private var canvasStore = CanvasStore()
    @State private var kanbanStore = KanbanStore()
    @State private var numbersService = NumbersService()
    @State private var whatsAppService = WhatsAppService()
    @State private var pluginService = PluginService()
    @State private var busWorker: BusWorker? = nil
    private let mcpService = MCPClientService()


    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
                .environment(catalog)
                .environment(visionProxyService)
                .environment(workspace)
                .environment(todoStore)
                .environment(planStore)
                .environment(messageStore)
                .environment(theme)
                .environment(skinStore)
                .environment(whisperService)
                .environment(notesViewModel)
                .environment(eventKitStore)
                .environment(appleNotesService)
                .environment(contactsService)
                .environment(canvasStore)
                .environment(kanbanStore)
                .environment(numbersService)
                .environment(whatsAppService)
                .environment(pluginService)
                .task {
                    appDelegate.mcpService = mcpService
                    appDelegate.whatsAppService = whatsAppService
                    pluginService.loadPlugins()
                    // Must complete before any agent could possibly dispatch a
                    // tool call — see ToolRegistry.swift's migration notes.
                    await MaestroTools.registerAllMigratedTools()
                    // Restore user settings from the external JSON backup if the
                    // UserDefaults plist has been reset or deleted. This must run
                    // before the observable stores read their initial values.
                    let didRestore = SettingsBackupService.shared.restoreIfNeeded()
                    if didRestore {
                        catalog.selectedModelID = UserDefaults.standard.string(forKey: ModelCatalog.selectedModelKey)
                            ?? catalog.selectedModelID
                        theme.reloadFromDefaults()
                    }
                    SwiftMaestroDefaultsMigration.applyIfNeeded()
                    // Migrate any pre-centralized app data into the single
                    // SwiftMaestro app root (data/, models/, logs/, backups/).
                    SwiftMaestroPaths.migrateFromFlatLayout()
                    // Create the shared ~/.ai-context scaffold up front so a fresh,
                    // self-contained install has its data directory before first use.
                    SimpleMemoryStore.ensureScaffold()
                    // Auto-configure web MCP servers (webclaw, firecrawl, read-website-fast)
                    // on first launch so agents can search the web immediately.
                    await WebSetupService.configureIfNeeded()
                    // Expose the workspace to native delegation/workspace tools.
                    MaestroTools.workspace = workspace
                    // One-time migration so existing installs get newly-added tool
                    // categories enabled by default without mutating state during UI
                    // rendering.
                    workspace.migrateEnabledToolCategories()
                    // Recover plans from previous builds and migrate them to the shared
                    // memory store so they survive workspace resets and reinstalls.
                    planStore.migrateFromLegacyStorage(navigatorID: workspace.navigator.id)
                    // Wire the vision proxy service to the live inference engine.
                    visionProxyService.setEngine(engine)
                    // Expose the live-todo store to the native todo tools.
                    MaestroTools.todoStore = todoStore
                    // Expose the plan store to the native plan tools.
                    MaestroTools.planStore = planStore
                    // Expose the inter-agent message store to the messaging tools.
                    MaestroTools.messageStore = messageStore
                    // Expose the workspace layout so tools can open/focus panels.
                    MaestroTools.workspaceLayout = WorkspaceLayoutState.shared
                    // Wire client-side MCP tools into the inference engine and
                    // spawn the user-enabled servers (permissioned by MCP flags).
                    engine.mcpService = mcpService
                    await mcpService.startEnabledServers()
                    // Expose the model catalog so tools (bus worker, etc.) can resolve
                    // an agent's effective model without coupling to the UI.
                    MaestroTools.catalog = catalog
                    // Create the persistent bus worker service and keep it alive.
                    let worker = BusWorker(engine: engine, mcpService: mcpService)
                    busWorker = worker
                    MaestroTools.busWorker = worker
                    // Validate capabilities for every locally-present model so
                    // tool-call format / thinking support are known before any
                    // generation runs. This is fast (JSON reads only).
                    await catalog.refreshCapabilities()
                    // Eagerly load the default model at startup so the first
                    // message doesn't block on model init/download. Avoid surprise
                    // downloads or OOM crashes: only auto-load models that are already
                    // present and fit comfortably within half of the installed RAM.
                    if let model = catalog.selectedModel,
                       model.hasCompleteLocalWeights {
                        let physicalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
                        let safeAutoLoadGB = max(32, physicalGB / 2)
                        if model.estimatedMemoryGB <= safeAutoLoadGB {
                            Task.detached(priority: .userInitiated) {
                                _ = try? await engine.loadModel(model)
                            }
                        }
                    }
                    // Eagerly load WhisperKit so the mic button is ready.
                    whisperService.notesVaultURL = notesViewModel.vaultURL
                    whisperService.ensureModelLoaded()
                    // Snapshot all user settings to ~/.config/SwiftMaestro/ so they
                    // survive plist deletion and can be synced via Chezmoi.
                    SettingsBackupService.shared.backup()
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

        // Floating chat window for any agent. Opens manually from the chat
        // toolbar or automatically when Navigator delegates to a sub-agent.
        WindowGroup("Agent Chat", id: "agent-chat-window", for: AgentChatWindowID.self) { $target in
            AgentChatWindowView(target: target)
                .environment(engine)
                .environment(catalog)
                .environment(visionProxyService)
                .environment(workspace)
                .environment(todoStore)
                .environment(planStore)
                .environment(messageStore)
                .environment(theme)
                .environment(whisperService)
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)

        // Floating panel windows (Tasks, Terminal, Plans). Opened when the user
        // pops a panel out from the main window's right column.
        WindowGroup("Panel", id: "floating-panel-window", for: FloatingPanelWindowID.self) { $target in
            if let target {
                FloatingPanelWindowView(target: target)
                    .environment(todoStore)
                    .environment(planStore)
                    .environment(theme)
            }
        }
        .defaultSize(width: 380, height: 520)
        .windowResizability(.contentMinSize)

        // Floating window for any top-level workspace panel (agent chat,
        // Notes.md, Apple Notes, Calendar, Reminders, Contacts, Canvas,
        // Kanban). Every panel after the first one the user opens defaults to
        // floating like this — they drag it wherever they like (including a
        // second monitor) and dock it back into the main window via its own
        // "Dock" button whenever they want.
        WindowGroup("Panel", id: "workspace-panel-window", for: WorkspacePanelWindowID.self) { $target in
            if let target {
                WorkspacePanelWindowView(target: target)
                    .environment(engine)
                    .environment(catalog)
                    .environment(visionProxyService)
                    .environment(workspace)
                    .environment(todoStore)
                    .environment(planStore)
                    .environment(messageStore)
                    .environment(theme)
                    .environment(whisperService)
                    .environment(notesViewModel)
                    .environment(eventKitStore)
                    .environment(appleNotesService)
                    .environment(contactsService)
                    .environment(canvasStore)
                    .environment(kanbanStore)
                    .environment(numbersService)
                    .environment(whatsAppService)
                    .environment(pluginService)
            }
        }
        .defaultSize(width: 500, height: 700)
        .windowResizability(.contentMinSize)

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
                .environment(catalog)
                .environment(visionProxyService)
                .environment(workspace)
                .environment(todoStore)
                .environment(planStore)
                .environment(messageStore)
                .environment(theme)
                .environment(skinStore)
                .environment(whisperService)
                .environment(\.mcpClientService, mcpService)
        }
        .defaultSize(width: 900, height: 960)
        // Settings scenes default to `.contentSize`, which pins the window to the
        // content's size (so it can't be resized). `.contentMinSize` enforces only
        // the content's MINIMUM, letting the user resize the window larger to use
        // available screen space (e.g. see the Appearance preview without scrolling).
        .windowResizability(.contentMinSize)
        #endif
    }
}
