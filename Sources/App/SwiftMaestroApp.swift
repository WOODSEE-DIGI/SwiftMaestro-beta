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

        purgeMailTrackingStateIfNeeded(defaults: defaults)
    }

    /// One-time purge of the removed mail-tracking feature's leftover state
    /// (the privacy cleanup deleted the code but not its data). The tracking
    /// event store is ARCHIVED, not deleted — it's user data (per-message
    /// open/click history) and the destructive-ops rule requires a recoverable
    /// backup. UserDefaults keys and the dead service's Keychain items go.
    private static func purgeMailTrackingStateIfNeeded(defaults: UserDefaults) {
        let purgeKey = "migration.mailTrackingPurge.v1"
        guard !defaults.bool(forKey: purgeKey) else { return }
        defaults.set(true, forKey: purgeKey)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let trackerDir = appSupport.appendingPathComponent("SwiftMaestro/mailtracker", isDirectory: true)
        if FileManager.default.fileExists(atPath: trackerDir.path) {
            let archiveDir = appSupport.appendingPathComponent(
                "SwiftMaestro/mailtracker-purged-20260814", isDirectory: true)
            try? FileManager.default.moveItem(at: trackerDir, to: archiveDir)
        }

        for key in ["owntrack.autoStartRelay", "owntrack.publicBaseURL",
                    "owntrack.signingSecret.fallback", "appleMail.relayBaseURL"] {
            defaults.removeObject(forKey: key)
        }
        for account in ["owntrack-signing-secret", "owntrack-relay-api-key"] {
            try? KeychainService.delete(account: account)
        }
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS 26 (Tahoe) crashes on launch when NSToolbar restores archived
        // toolbar state that contains an NSCalendarDate — a relic of the old
        // toolbar item serialization. The crash happens DURING toolbar
        // initialization (before any SwiftUI lifecycle hooks run), so we must
        // purge the stale toolbar configuration from UserDefaults here.
        let defaults = UserDefaults.standard
        let keysToRemove = defaults.dictionaryRepresentation().keys.filter {
            $0.contains("Toolbar") || $0.contains("toolbar")
        }
        for key in keysToRemove {
            defaults.removeObject(forKey: key)
        }

        // Decide BEFORE any window appears whether this launch has first-run
        // dependency install work, so ContentView can present the setup
        // progress sheet instead of the welcome sheet with no flicker — a new
        // user's first experience is a named, live activity feed, never a
        // spinning beachball.
        SetupProgressService.shared.plan()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After a crash, macOS may restore stale windows from its own state
        // restoration that don't correspond to any live SwiftUI WindowGroup.
        // These phantom windows produce "Invalid window" constraint errors
        // (CDXPackagesSetWindowConstraints) and may overlap the main window
        // without ever reaching a usable layout.
        //
        // Our own code (ContentView.onAppear + SwiftMaestroApp.task) reopens
        // the correct windows from WorkspaceLayoutState. Close any windows
        // macOS already restored in this launch that aren't the main window.
        Task { @MainActor in
            // Wait briefly so the main window has time to establish itself
            // as NSApp.mainWindow.
            try? await Task.sleep(for: .milliseconds(300))
            guard let main = NSApp.mainWindow else { return }
            for window in NSApp.windows where window != main {
                // Keep Settings, About, and system-level windows alive.
                guard window.level == .normal else { continue }
                let isSettings = window.title == "Settings"
                let isAbout = window.title == "About"
                if !isSettings && !isAbout {
                    window.close()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize any in-progress voice note (header flush + duration). The
        // audio data is already on disk; this just makes the WAV well-formed.
        VoiceNotesStore.shared.finalizeForAppQuit()
        // Privacy: wipe WebKit cookies/cache/storage on quit when the user
        // enabled "clear site data on quit" in SwiftBrowser's Privacy popover.
        if UserDefaults.standard.bool(forKey: "browser.clearOnQuit") {
            BrowserPrivacyStore.clearAllSiteDataSync()
        }
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
    @Environment(\.openWindow) private var openWindow
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
        // ACP agent mode: when launched with --acp, run as a headless JSON-RPC
        // agent over stdin/stdout instead of starting the SwiftUI app.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--acp") {
            SwiftMaestroDefaultsMigration.applyIfNeeded()
            let engine = MLXInferenceEngine()
            let catalog = ModelCatalog()
            let agent = ACPAgent(engine: engine, catalog: catalog)
            Task {
                await agent.run()
                exit(0)
            }
            RunLoop.main.run()
        }

        let theme = ThemeStore()
        _theme = State(wrappedValue: theme)
        _skinStore = State(wrappedValue: SkinStore(theme: theme))

        // Register the global push-to-talk hotkey if the user has configured one.
        // Stream Deck can be programmed to send this key; holding it starts
        // WhisperKit recording, releasing it stops and (with auto-send) submits.
        GlobalHotkeyManager.shared.register(
            keyCode: whisperService.pushToTalkKeyCode,
            service: whisperService
        )
    }
    @State private var visionProxyService = VisionProxyService()
    @State private var notesViewModel = NotesViewModel()
    @State private var eventKitStore = EventKitStore()
    @State private var appleNotesService = AppleNotesService()
    @State private var contactsService = ContactsService()
    @State private var whiteboardStore = WhiteboardStore()
    @State private var kanbanStore = KanbanStore()
    @State private var numbersService = NumbersService()
    @State private var mapsService = AppleMapsService.shared
    @State private var photosService = ApplePhotosService()
    @State private var mailService = AppleMailService.shared
    @State private var whatsAppService = WhatsAppService()
    @State private var discordService = DiscordService()
    @State private var pluginService = PluginService()
    @State private var busWorker: BusWorker? = nil
    @State private var sparkleUpdater = SparkleUpdaterService.shared
    @State private var webBrowserStore = WebBrowserStore.shared
    @State private var workspaceLayout = WorkspaceLayoutState.shared
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
                .environment(whiteboardStore)
                .environment(kanbanStore)
                .environment(numbersService)
                .environment(mapsService)
                .environment(photosService)
                .environment(mailService)
                .environment(whatsAppService)
                .environment(discordService)
                .environment(pluginService)
                .environment(sparkleUpdater)
                .environment(webBrowserStore)
                .task {
                    appDelegate.mcpService = mcpService
                    appDelegate.whatsAppService = whatsAppService
                    pluginService.loadPlugins()
                    // Must complete before any agent could possibly dispatch a
                    // tool call — see ToolRegistry.swift's migration notes.
                    await MaestroTools.registerAllMigratedTools()
                    // Install the OpenCode-style permission checker so project
                    // .opencode/permissions.json and .ai-context/permissions.json
                    // policies can allow/ask/deny tools and paths.
                    await ToolRegistry.shared.setPermissionChecker(PermissionService.shared)
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
                    // Prove the data dir is writable — the persistence layer
                    // used to fail silently via `try?`; one [PERSIST] line per
                    // launch makes its health visible in Console.
                    SwiftMaestroPaths.performPersistenceCanary()
                    // Create the shared ~/.ai-context scaffold up front so a fresh,
                    // self-contained install has its data directory before first use.
                    SimpleMemoryStore.ensureScaffold()
                    // First-run dependency installation. The services are all
                    // nonisolated, so their heavy synchronous work (extraction,
                    // npm installs, per-binary codesigning, multi-GB model
                    // hardlink/copy) runs OFF the main thread — no beachball —
                    // while the setup progress sheet names each item live.
                    let setupProgress = SetupProgressService.shared
                    let setupReporter = SetupReporter()
                    if setupProgress.hasPendingWork {
                        setupProgress.beginPlannedWork()
                    }
                    // Extract and install any MCP servers bundled inside the app bundle
                    // into ~/Library/Application Support/SwiftMaestro/mcp-servers/. This is
                    // the foundation for a one-click install .dmg with no external deps.
                    do {
                        _ = try await MCPServerBundleService.shared.installIfNeeded(progress: setupReporter)
                    } catch {
                        NSLog("[SwiftMaestroApp] MCP server bundle installation failed: %@", error.localizedDescription)
                        await setupReporter.finish(SetupStepID.mcpServers, .failed(error.localizedDescription))
                    }
                    // If bundled servers were installed, update the saved MCP server list
                    // so their resolved paths are used instead of the hardcoded defaults.
                    await MCPServerBundleService.shared.applyBundledServersIfNeeded()
                    // Install the default bundled model from the app bundle into the
                    // canonical ~/Ai-models/models/ root. Hardlinks are used when the app
                    // bundle and model root share a filesystem; otherwise an awaited
                    // copy runs. This makes the "full" .dmg work immediately after the
                    // user drags the app to /Applications.
                    _ = await BundledModelService.shared.installIfNeeded(progress: setupReporter)
                    // Auto-configure web MCP servers (webclaw, firecrawl, read-website-fast)
                    // on first launch so agents can search the web immediately.
                    await WebSetupService.configureIfNeeded(progress: setupReporter)
                    if setupProgress.isRunning {
                        setupProgress.complete()
                    }
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
                    // spawn the user-enabled MCP servers (permissioned by MCP flags).
                    engine.mcpService = mcpService
                    await mcpService.startEnabledServers()
                    // Expose the model catalog so tools (bus worker, etc.) can resolve
                    // an agent's effective model without coupling to the UI.
                    MaestroTools.catalog = catalog
                    // Create the persistent bus worker service and keep it alive.
                    let worker = BusWorker(engine: engine, mcpService: mcpService)
                    busWorker = worker
                    MaestroTools.busWorker = worker
                    // System health watchdog: crash/hang notifications → "Diagnose
                    // with Maestro" seeds the Navigator chat with the crash context.
                    SystemHealthWatchService.shared.onDiagnose = { summary in
                        let navigator = workspace.navigator
                        let model = catalog.effectiveModel(for: navigator)
                        let vm = ChatViewModelCache.shared.viewModel(
                            for: navigator,
                            projectName: workspace.projectName(for: navigator))
                        vm.inputText = SystemHealthWatchService.diagnosticPrompt(for: summary)
                        // Privacy gate: auto-send only to local models; a remote
                        // provider gets a pre-filled draft the user reviews first
                        // (crash reports can contain paths and usernames).
                        if let model, !model.isRemote {
                            vm.send(engine: engine, catalog: catalog, model: model)
                        }
                        openOrFocusPanel(.agentChat(navigator.id))
                    }
                    SystemHealthWatchService.shared.start()
                    // Ensure the Mechanic support agent exists, and once the bundled
                    // Qwen3-4B is on disk (DMG install or Models-tab download), default
                    // the Mechanic to it so help works with no other model configured.
                    let mechanic = workspace.mechanic
                    if mechanic.modelID == nil, ModelCatalog.mechanicModelAvailable {
                        workspace.setModel(ModelCatalog.mechanicModelID, for: mechanic.id)
                    }
                    // Developer machines: give the Mechanic the SwiftMaestro repo as
                    // its working directory so git history + docs/ are authorized
                    // tool scope (it can consult known-good committed state when
                    // diagnosing). End users have no repo — they keep the default
                    // app-support root, which is always authorized.
                    if mechanic.workingDirectory == nil {
                        let repo = NSHomeDirectory() + "/GitHub/FUSV/SwiftMaestro"
                        if FileManager.default.fileExists(atPath: repo + "/.git") {
                            workspace.setWorkingDirectory(repo, for: mechanic.id)
                        }
                    }
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
                    // Voice Notes: wire the transcription + Notes.md export
                    // services (also kicks off any recovered/queued notes).
                    VoiceNotesStore.shared.attach(whisper: whisperService, notesVault: notesViewModel.vaultURL)
                    // Reopen secondary canvas windows from the last session.
                    for window in WorkspaceLayoutState.shared.canvasWindows {
                        openWindow(id: "canvas-window", value: window.id)
                    }
                    // Snapshot all user settings to ~/.config/SwiftMaestro/ so they
                    // survive plist deletion and can be synced via Chezmoi.
                    SettingsBackupService.shared.backup()
                }
        }
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // Window > panel recovery menu. All dynamic lists are computed
            // HERE in the scene body so @Observable tracking rebuilds the
            // menus the moment the layout, agents, plugins, or app-enablement
            // state changes — never inside the Commands value, which SwiftUI
            // would not observe.
            PanelCommands(
                layout: workspaceLayout,
                navigator: workspace.navigator,
                agentGroups: workspace.projectAgentsByCategory(),
                categorizedPanels: AppCategory.allCases.filter { !$0.isHidden }.map { category in
                    (category: category, kinds: AppEnablementStore.shared.visibleKinds(in: category))
                }.filter { !$0.kinds.isEmpty },
                builtInPlugins: AppCategory.builtInPluginKinds.filter {
                    AppEnablementStore.shared.showsBuiltInPlugin($0)
                },
                plugins: pluginService.plugins.filter {
                    AppEnablementStore.shared.showsPlugin($0.id)
                },
                openPanels: Set(workspaceLayout.allOpenPanels),
                canvasWindows: workspaceLayout.canvasWindows,
                openCanvasWindowIDs: workspaceLayout.openCanvasWindowIDs
            )
        }


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
        // toolbar or automatically when Maestro delegates to a sub-agent.
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
                    .environment(whiteboardStore)
                    .environment(kanbanStore)
                    .environment(numbersService)
                    .environment(mapsService)
                .environment(photosService)
                .environment(mailService)
                .environment(whatsAppService)
                .environment(discordService)
                .environment(pluginService)
                .environment(webBrowserStore)
            }
        }
        .defaultSize(width: 500, height: 700)
        .windowResizability(.contentMinSize)


        // Secondary canvas windows: each hosts a full free-tile canvas (the
        // same view as the main workspace), so a group of panels can live as
        // ONE window on a second display rather than N floating windows.
        // Tiles travel between canvases via the panel's ⋯ → "Move to" menu.
        WindowGroup("Canvas", id: "canvas-window", for: UUID.self) { $canvasID in
            if let canvasID {
                CanvasWorkspaceView(canvasID: canvasID)
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
                    .environment(whiteboardStore)
                    .environment(kanbanStore)
                    .environment(numbersService)
                    .environment(mapsService)
                    .environment(photosService)
                    .environment(mailService)
                    .environment(whatsAppService)
                    .environment(discordService)
                    .environment(pluginService)
                    .environment(webBrowserStore)
            }
        }
        .defaultSize(width: 1_100, height: 800)
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
                .environment(sparkleUpdater)
                // The Settings → Apps tab lists installed plugins, so it needs the
                // same PluginService the main window uses (the single @State instance
                // already populated by loadPlugins() at launch).
                .environment(pluginService)
        }
        .defaultSize(width: 900, height: 960)
        // Settings scenes default to `.contentSize`, which pins the window to the
        // content's size (so it can't be resized). `.contentMinSize` enforces only
        // the content's MINIMUM, letting the user resize the window larger to use
        // available screen space (e.g. see the Appearance preview without scrolling).
        // Pomodoro menu-bar extra — the pomarchy pattern on macOS: icon +
        // live counter always visible; left-click opens the state-aware menu.
        MenuBarExtra {
            PomodoroMenuBarMenu(store: PomodoroStore.shared) {
                openOrFocusPanel(.pomodoro)
            }
        } label: {
            PomodoroMenuBarLabel(store: PomodoroStore.shared)
        }
        .menuBarExtraStyle(.menu)
        #endif
    }

    /// Menu-bar companion to `PanelCommands.openOrFocus`: dock the panel into
    /// the grid, or front it (floating window / canvas tile) when already open.
    private func openOrFocusPanel(_ kind: WorkspacePanelKind) {
        switch workspaceLayout.open(kind) {
        case .floated:
            openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
        case .alreadyOpen:
            if workspaceLayout.isFloating(kind) {
                openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
            } else if let tile = workspaceLayout.canvasTile(containing: kind) {
                workspaceLayout.bringTileToFront(tile.id)
            }
            NotificationCenter.default.post(name: .bringWorkspacePanelToFront, object: kind)
        case .dockedDirectly:
            break
        }
    }
}

// MARK: - Window Menu Panel Commands

/// Window > panel commands: open, reopen, or focus any workspace panel.
/// This is the recovery path when a panel was closed (the ✕ on its tile) or
/// its floating window vanished — previously the only way back was the
/// Agents / Apps Launcher panels, which could themselves be closed with no
/// way back. All dynamic content is snapshotted by the app scene body (which
/// owns the @Observable tracking) and passed in as plain values, so the menus
/// are always current when opened.
private struct PanelCommands: Commands {
    let layout: WorkspaceLayoutState
    let navigator: AgentRecord
    let agentGroups: [(category: AgentCategory, agents: [AgentRecord])]
    let categorizedPanels: [(category: AppCategory, kinds: [WorkspacePanelKind])]
    let builtInPlugins: [WorkspacePanelKind]
    let plugins: [PluginManifest]
    /// Open panel kinds at body-evaluation time — drives the checkmarks.
    let openPanels: Set<WorkspacePanelKind>
    /// Secondary canvas windows (persisted) and which of them are actually on
    /// screen right now — drives the Canvas Windows reopen section.
    let canvasWindows: [CanvasWindowInfo]
    let openCanvasWindowIDs: Set<UUID>

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            // Recovery-critical chrome first: if these get closed there is no
            // other in-app path back to the navigator or the launcher.
            panelButton(.agents)
                .keyboardShortcut("0", modifiers: .command)
            panelButton(.appLauncher)

            Divider()

            agentChatsMenu
            panelsMenu

            // Canvas windows: closing one used to strand its tiles invisibly
            // until the next app restart. Reopen (or focus) from here — and
            // Close Canvas Window removes it entirely (tiles migrate back to
            // the main canvas).
            if !canvasWindows.isEmpty {
                Divider()
                Section("Canvas Windows") {
                    ForEach(canvasWindows) { window in
                        Menu {
                            Button {
                                openWindow(id: "canvas-window", value: window.id)
                            } label: {
                                Label(
                                    openCanvasWindowIDs.contains(window.id) ? "Focus Window" : "Reopen Window",
                                    systemImage: "rectangle.on.rectangle"
                                )
                            }
                            Divider()
                            Button(role: .destructive) {
                                layout.removeCanvasWindow(id: window.id)
                            } label: {
                                Label("Close Canvas Window", systemImage: "xmark.rectangle")
                            }
                        } label: {
                            Label(
                                window.name,
                                systemImage: openCanvasWindowIDs.contains(window.id)
                                    ? "checkmark" : "rectangle.on.rectangle"
                            )
                        }
                    }
                }
            }

            Divider()

            Button("New Canvas Window") {
                let info = layout.createCanvasWindow()
                openWindow(id: "canvas-window", value: info.id)
            }

            Divider()

            Button("Reset Layout to Default") {
                layout.resetToDefaultLayout()
            }

            Divider()
        }
    }

    // MARK: Agent Chats submenu

    @ViewBuilder
    private var agentChatsMenu: some View {
        Menu("Agent Chats") {
            panelButton(.agentChat(navigator.id), title: navigator.name)
            if !agentGroups.isEmpty {
                Divider()
                ForEach(agentGroups, id: \.category) { group in
                    Section(group.category.displayName) {
                        ForEach(group.agents) { agent in
                            panelButton(.agentChat(agent.id), title: agent.name)
                        }
                    }
                }
            }
        }
    }

    // MARK: Panels submenu

    @ViewBuilder
    private var panelsMenu: some View {
        Menu("Panels") {
            ForEach(categorizedPanels, id: \.category) { group in
                Section(group.category.title) {
                    ForEach(group.kinds, id: \.self) { kind in
                        panelButton(kind)
                    }
                }
            }
            if !builtInPlugins.isEmpty || !plugins.isEmpty {
                Section("Plugins") {
                    ForEach(builtInPlugins, id: \.self) { kind in
                        panelButton(kind)
                    }
                    ForEach(plugins) { manifest in
                        panelButton(.plugin(manifest.id), title: manifest.name, icon: manifest.icon)
                    }
                }
            }
        }
    }

    // MARK: One menu item

    /// A checkmark replaces the icon while the panel is open; clicking an
    /// open panel focuses it rather than closing it (these are not toggles).
    private func panelButton(
        _ kind: WorkspacePanelKind,
        title: String? = nil,
        icon: String? = nil
    ) -> some View {
        let isOpen = openPanels.contains(kind)
        return Button {
            openOrFocus(kind)
        } label: {
            Label(
                title ?? kind.staticDisplayName ?? "Panel",
                systemImage: isOpen ? "checkmark" : (icon ?? kind.icon)
            )
        }
    }

    // MARK: Open / focus

    /// Mirrors `ContentView.openPanel`: open when closed; when already open,
    /// front the floating window or raise the docked tile, and ping the
    /// bring-to-front notifications so detached agent windows respond too.
    private func openOrFocus(_ kind: WorkspacePanelKind) {
        switch layout.open(kind) {
        case .floated:
            openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
        case .alreadyOpen:
            if layout.isFloating(kind) {
                openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
            } else if let tile = layout.canvasTile(containing: kind) {
                layout.bringTileToFront(tile.id)
            }
            NotificationCenter.default.post(name: .bringWorkspacePanelToFront, object: kind)
            if case .agentChat(let id) = kind {
                NotificationCenter.default.post(name: .bringAgentChatToFront, object: id)
            }
        case .dockedDirectly:
            break
        }
    }
}
