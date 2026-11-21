import SwiftUI
import AppKit
import SwiftMaestroKit

// MARK: - Agents Window

/// The app's control centre and launch window.
///
/// With the canvas gone there is no "main window" holding a grid of tiles —
/// this is the one window that always exists: the Agents list plus the
/// toolbar chrome that used to live in `ContentView` (workspace switcher,
/// model picker, pomodoro, layout presets). It is also the app's sheet host
/// and the launch point for the one-time bootstrap sequence.
struct AgentsWindowView: View {
    /// Shared MCP client, wired into `AppDelegate` during bootstrap.
    let mcpService: MCPClientService

    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(VisionProxyService.self) private var visionProxyService
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(ThemeStore.self) private var theme
    @Environment(WhisperKitService.self) private var whisper
    @Environment(NotesViewModel.self) private var notesViewModel
    @Environment(PluginService.self) private var pluginService
    @Environment(WhatsAppService.self) private var whatsAppService
    @Environment(TodoStore.self) private var todoStore
    @Environment(OSINTProfileStore.self) private var osintProfileStore
    @Environment(PlanStore.self) private var planStore
    @Environment(MacroStore.self) private var macroStore
    @Environment(\.openWindow) private var openWindow

    @Bindable private var coordinator = WorkspaceCoordinator.shared
    @State private var layout = WorkspaceLayoutState.shared
    @State private var chatCache = ChatViewModelCache.shared

    // New-agent / preset sheet fields.
    @State private var newProjectName = ""
    @State private var newAgentName = ""
    @State private var newAgentCategory: AgentCategory = .general
    @State private var newPresetName = ""
    @State private var newPresetSlot = 1

    // First-run sheet chain.
    @AppStorage("onboarding.seenV1") private var onboardingSeen = false
    @AppStorage("welcome.seenV1") private var welcomeSeen = false
    @AppStorage("whisperkit.seenV1") private var whisperKitSeen = false
    @AppStorage("notes.icloudOnboardingSeen") private var notesOnboardingSeen = false
    @State private var setupProgress = SetupProgressService.shared
    @State private var setupSheetHandled = false
    /// True once the pending sheet has been handed to this window — the
    /// appear-nudge below must not re-offer the same sheet forever.
    @State private var presentedPendingSheet = false

    var body: some View {
        VStack(spacing: 0) {
            chromeBar
            Divider()
            AgentsPanelView()
        }
        .frame(minWidth: 240, minHeight: 420)
        .tint(theme.accent)
        .preferredColorScheme(theme.appearance.colorScheme)
        .background(theme.background)
        #if os(macOS)
        .background(
            WindowSizeConfigurator(
                minSize: CGSize(width: 240, height: 420),
                defaultSize: CGSize(width: 300, height: 720),
                backgroundColor: nil,
                forceDefaultSize: true
            )
        )
        // Remember where the user put the Agents window across relaunches and
        // workspace-layout recalls.
        .background(WindowFrameConfigurator(kind: .agents))
        .background(WindowCascadeConfigurator())
        .background(
            WindowCloseObserver {
                layout.close(.agents)
                coordinator.isAgentsWindowPresented = false
            }
        )
        #endif
        .sheet(item: $coordinator.activeSheet) { sheet in
            switch sheet {
            case .newAgent:
                newAgentSheet
            case .onboarding:
                OnboardingView(onDone: { onboardingSeen = true; coordinator.activeSheet = nil; advanceFirstRunSheets() })
                    .environment(catalog)
                    .environment(engine)
            case .diagnosticReport(let description, let mediaPath):
                DiagnosticReportView(initialDescription: description, initialMediaPath: mediaPath)
            case .welcome:
                WelcomeView(onDone: { welcomeSeen = true; coordinator.activeSheet = nil; advanceFirstRunSheets() })
                    .environment(catalog)
                    .environment(engine)
            case .setup:
                SetupProgressView(
                    onContinueInBackground: {
                        coordinator.activeSheet = nil
                        advanceFirstRunSheets()
                    },
                    onFinished: {
                        coordinator.activeSheet = nil
                        advanceFirstRunSheets()
                    }
                )
            case .whisperSetup:
                WhisperKitSetupSheet(onDone: { whisperKitSeen = true; coordinator.activeSheet = nil })
                    .environment(whisper)
            case .notesOnboarding:
                NotesOnboardingSheet(onDone: { coordinator.activeSheet = nil })
            case .agentCategory(let agent):
                agentCategorySheet(for: agent)
            case .savePreset:
                savePresetSheet
            }
        }
        .onChange(of: whisper.modelState) { _, newState in
            handleWhisperStateChange(newState)
        }
        .onAppear {
            coordinator.installObserversIfNeeded()
            coordinator.bindOpenWindow { kind in
                if kind == .agents {
                    openWindow(id: "agents-window")
                } else {
                    openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
                }
            }
            coordinator.isAgentsWindowPresented = true

            // A sheet requested while this window was closed is offered now
            // that it can actually present. Re-assigning through nil guarantees
            // SwiftUI notices a value that was already set before attachment.
            if let pending = coordinator.activeSheet, !presentedPendingSheet {
                presentedPendingSheet = true
                coordinator.activeSheet = nil
                DispatchQueue.main.async {
                    coordinator.activeSheet = pending
                }
            }

            // Launch chrome: the Agents list (this window) plus the Apps
            // launcher. A saved layout keeps its own set — only a genuinely
            // empty workspace gets the defaults pushed onto it. Either way,
            // this window is on screen right now, so the layout must agree
            // that `.agents` is open (a previous session may have closed it
            // while SwiftUI still reopens this default window at launch).
            if layout.canvasTiles.isEmpty && layout.floatingPanels.isEmpty {
                layout.ensureChromeLayout(navigatorID: workspace.navigator.id)
            } else if !layout.allOpenPanels.contains(.agents) {
                layout.open(.agents)
            }

            // Explicitly (re)present every panel that was floating when the app
            // last quit, rather than relying solely on macOS to restore
            // data-driven WindowGroup windows — that restoration isn't
            // guaranteed, and when it doesn't happen the persisted state and
            // reality silently disagree. The one-second delay is the same
            // race-avoidance as before: `openWindow` can only dedup against a
            // window SwiftUI already knows about, and system restoration
            // registers its windows a beat later.
            Task {
                try? await Task.sleep(for: .seconds(1))
                for kind in layout.floatingPanels where kind != .agents {
                    openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
                }
            }

            chatCache.setVisionProxyService(visionProxyService)
            // When a delegation starts, open/front a floating chat window for
            // the sub-agent so the user can watch Maestro and Scribe side-by-side.
            chatCache.onOpenAgentWindow = { agentID in
                coordinator.openPanel(.agentChat(agentID))
            }

            if coordinator.activeSheet == nil {
                advanceFirstRunSheets()
            }

            WorkspaceBootstrap.shared.start { await runLaunchBootstrap() }
        }
        .task {
            // Prime every agent's inbox from disk so sidebar unread badges are
            // accurate at launch (not just for the open agent).
            for agent in workspace.agents { _ = messageStore.inbox(for: agent.id) }
            // Notes iCloud onboarding is handled in WelcomeView; mark the old
            // sheet as seen so it never re-appears.
            if !notesOnboardingSeen && welcomeSeen {
                notesOnboardingSeen = true
            }
        }
    }

    // MARK: - Chrome bar

    /// The toolbar that used to live in the main window's title bar, now
    /// pinned to the top of the Agents window. Stacked vertically so the
    /// workspace switcher sits above the agent list and the control row
    /// (model, pomodoro, presets, new agent) stays compact.
    private var chromeBar: some View {
        @Bindable var catalog = catalog

        return VStack(spacing: 6) {
            WorkspaceSwitcherView()

            HStack(spacing: 8) {
                modelPickerMenu(catalog: catalog)
                Spacer(minLength: 0)
                PomodoroTitleBarTimer(store: PomodoroStore.shared) {
                    coordinator.openPanel(.pomodoro)
                }
                presetMenu
                Button {
                    coordinator.presentSheet(.newAgent)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New project agent")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func modelPickerMenu(catalog: ModelCatalog) -> some View {
        Menu {
            let groups = ModelVisibilityStore.shared.groupedModels(
                ModelVisibilityStore.shared.visibleModels(from: catalog.models)
            )
            ForEach(groups, id: \.sourceID) { group in
                Section(group.name) {
                    ForEach(group.models) { model in
                        Button {
                            catalog.selectedModelID = model.id
                        } label: {
                            Label {
                                Text(model.displayName)
                            } icon: {
                                Image(nsImage: ChatView.badgeDotImage(model.providerBadge.colorName))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let selected = catalog.selectedModel {
                    Image(nsImage: ChatView.badgeDotImage(selected.providerBadge.colorName))
                    Text(selected.displayName)
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("Select model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: .capsule)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 120)
        .help("Global default model — used by any agent whose model is set to “Default (global)”.")
    }

    private var presetMenu: some View {
        Menu {
            let presetStore = WorkspaceLayoutPresetStore.shared
            ForEach(presetStore.presets) { preset in
                Button {
                    presetStore.recall(preset.id)
                } label: {
                    HStack {
                        Text(preset.name)
                        if presetStore.activePresetID == preset.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("Save Current Layout…") {
                coordinator.presentSheet(.savePreset)
            }
            Button("Reset Window Positions") {
                layout.resetToDefaultLayout()
                FloatingWindowFrameStore.shared.resetAll()
            }
        } label: {
            Image(systemName: "rectangle.on.rectangle.angled")
        }
        .menuStyle(.borderlessButton)
        .help("Workspace layouts — save, recall, or reset window positions")
    }

    // MARK: - New project agent sheet

    private var newAgentSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project Agent").font(.title3.bold())
            Text("Creates the project if it doesn't exist yet.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("Project name", text: $newProjectName)
                TextField("Agent name", text: $newAgentName)
                Picker("Category", selection: $newAgentCategory) {
                    ForEach(AgentCategory.allCases) { category in
                        HStack(spacing: 4) {
                            Image(systemName: category.systemImage)
                            Text(category.displayName)
                        }
                        .tag(category)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Spacer()
                Button("Cancel") { resetNewAgent() }
                Button("Create") { createAgent() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        newProjectName.trimmingCharacters(in: .whitespaces).isEmpty
                            || newAgentName.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func agentCategorySheet(for agent: AgentRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Category").font(.title3.bold())
            Text("Choose the category for \(agent.name). This affects the sidebar grouping, system prompt, and default tools.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                Picker("Category", selection: .init(
                    get: { workspace.resolvedCategory(for: agent) },
                    set: { workspace.setCategory($0, for: agent.id) }
                )) {
                    ForEach(AgentCategory.allCases) { category in
                        HStack(spacing: 4) {
                            Image(systemName: category.systemImage)
                            Text(category.displayName)
                        }
                        .tag(category)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            HStack {
                Spacer()
                Button("Done") { coordinator.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var savePresetSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Workspace Layout").font(.title3.bold())
            Text("Assign this layout to a numbered slot in the workspace switcher.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("Layout name", text: $newPresetName)
                Picker("Slot", selection: $newPresetSlot) {
                    ForEach(1...10, id: \.self) { slot in
                        let existing = WorkspaceLayoutPresetStore.shared.preset(forSlot: slot)
                        Text("\(slot == 10 ? "0" : "\(slot)")\(existing.map { " — \($0.name)" } ?? "")")
                            .tag(slot)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { newPresetName = ""; coordinator.activeSheet = nil }
                Button("Save") {
                    WorkspaceLayoutPresetStore.shared.saveToSlot(newPresetSlot, name: newPresetName)
                    newPresetName = ""
                    coordinator.activeSheet = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func createAgent() {
        let created = workspace.createProjectAgent(
            projectName: newProjectName.trimmingCharacters(in: .whitespaces),
            agentName: newAgentName.trimmingCharacters(in: .whitespaces),
            category: newAgentCategory
        )
        coordinator.openPanel(.agentChat(created.id))
        resetNewAgent()
    }

    private func resetNewAgent() {
        newProjectName = ""
        newAgentName = ""
        newAgentCategory = .general
        coordinator.activeSheet = nil
    }

    // MARK: - First-run sheet chain

    /// Advances the first-run sheet sequence: setup → welcome → onboarding →
    /// whisper. Each sheet's completion handler calls this to present the next
    /// one due; `.onAppear` kicks off the chain.
    ///
    /// The whisper step exists because first launch loads the speech model
    /// into memory (a slow first CoreML compile) with otherwise NO visible
    /// indication — the sheet explains the wait and dismisses itself when ready.
    private func advanceFirstRunSheets() {
        // 1. Dependency setup (only when this launch actually installs things).
        if !setupSheetHandled && (setupProgress.hasPendingWork || setupProgress.isRunning) {
            setupSheetHandled = true
            coordinator.activeSheet = .setup
            return
        }
        // 2. Welcome screen: shown once before model selection.
        if !welcomeSeen {
            coordinator.activeSheet = .welcome
            return
        }
        // 3. Model picker for fresh installs (no model files on disk yet).
        if !onboardingSeen && !catalog.models.contains(where: { $0.localPath != nil }) {
            coordinator.activeSheet = .onboarding
            return
        }
        // 4. Whisper speech model: until it has finished loading ONCE. Gate on
        //    the live model state, not just file presence — a bundled model is
        //    on disk immediately but still needs its long first load.
        if !whisperKitSeen {
            if whisper.modelState == .loaded {
                whisperKitSeen = true
            } else {
                if whisper.modelState == .unloaded {
                    whisper.ensureModelLoaded()
                }
                coordinator.activeSheet = .whisperSetup
            }
        }
    }

    private func handleWhisperStateChange(_ newState: WKModelState) {
        guard !whisperKitSeen, coordinator.activeSheet == nil else { return }
        let isPreparing: Bool
        switch newState {
        case .downloading, .loading, .prewarming:
            isPreparing = true
        default:
            isPreparing = false
        }
        if isPreparing {
            coordinator.activeSheet = .whisperSetup
        }
    }

    // MARK: - Launch bootstrap

    /// The one-time launch sequence, moved verbatim from the old main
    /// window's `.task`. `WorkspaceBootstrap` runs it exactly once for the
    /// process, so closing this window mid-flight cannot cancel a half-done
    /// MCP/model/tool setup.
    private func runLaunchBootstrap() async {
        let appDelegate = NSApp.delegate as? AppDelegate
        appDelegate?.mcpService = mcpService
        appDelegate?.whatsAppService = whatsAppService
        CRMContactCardService.shared.whatsAppService = whatsAppService
        pluginService.loadPlugins()
        BrowserExtensionService.shared.loadExtensions()
        // Must complete before any agent could possibly dispatch a tool call —
        // see ToolRegistry.swift's migration notes.
        await MaestroTools.registerAllMigratedTools()
        // Install the OpenCode-style permission checker so project
        // .opencode/permissions.json and .ai-context/permissions.json
        // policies can allow/ask/deny tools and paths.
        await ToolRegistry.shared.setPermissionChecker(PermissionService.shared)
        // Clear saved frames for the launch windows whose default sizes just
        // changed, so the new defaults (narrower Agents, wider Apps) are
        // visible without a manual Reset Window Positions.
        FloatingWindowFrameStore.shared.migrateLauncherFramesIfNeeded()

        // Restore user settings from the external JSON backup if the
        // UserDefaults plist has been reset or deleted. This must run before
        // the observable stores read their initial values.
        let didRestore = SettingsBackupService.shared.restoreIfNeeded()
        if didRestore {
            catalog.selectedModelID = UserDefaults.standard.string(forKey: ModelCatalog.selectedModelKey)
                ?? catalog.selectedModelID
            theme.reloadFromDefaults()
        }
        SwiftMaestroDefaultsMigration.applyIfNeeded()
        // Migrate any pre-centralized app data into the single SwiftMaestro
        // app root (data/, models/, logs/, backups/).
        SwiftMaestroPaths.migrateFromFlatLayout()
        // Prove the data dir is writable — the persistence layer used to fail
        // silently via `try?`; one [PERSIST] line per launch makes its health
        // visible in Console.
        SwiftMaestroPaths.performPersistenceCanary()
        // Create the shared ~/.ai-context scaffold up front so a fresh,
        // self-contained install has its data directory before first use.
        SimpleMemoryStore.ensureScaffold()
        // Warm the SQLite FTS memory index in the background so the first
        // memory_search doesn't pay the (multi-minute) full-store build on the
        // caller's critical path.
        await MemorySearchService.shared.warm()
        // First-run dependency installation. Heavy synchronous work runs OFF
        // the main thread — no beachball — while the setup progress sheet
        // names each item live.
        let setupProgress = SetupProgressService.shared
        let setupReporter = SetupReporter()
        if setupProgress.hasPendingWork {
            setupProgress.beginPlannedWork()
        }
        // Extract and install any MCP servers bundled inside the app bundle
        // into ~/Library/Application Support/SwiftMaestro/mcp-servers/.
        do {
            _ = try await MCPServerBundleService.shared.installIfNeeded(progress: setupReporter)
        } catch {
            NSLog("[SwiftMaestroApp] MCP server bundle installation failed: %@", error.localizedDescription)
            await setupReporter.finish(SetupStepID.mcpServers, .failed(error.localizedDescription))
        }
        // If bundled servers were installed, update the saved MCP server list
        // so their resolved paths are used instead of the hardcoded defaults.
        await MCPServerBundleService.shared.applyBundledServersIfNeeded()
        // Install the ArtCraft Crafting Apps payload and register their MCP
        // servers — must happen before startEnabledServers() below so the
        // agent's first turn can use them.
        do {
            try CraftAppInstallService.shared.installIfNeeded()
        } catch {
            NSLog("[SwiftMaestroApp] Craft app installation failed: %@", error.localizedDescription)
        }
        await CraftAppInstallService.shared.registerMCPEntriesIfNeeded()
        // Install the default bundled model from the app bundle into the
        // canonical <model-directory>/models/ root.
        _ = await BundledModelService.shared.installIfNeeded(progress: setupReporter)
        // Auto-configure web MCP servers on first launch so agents can search
        // the web immediately.
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
        // Hide project scopes whose plans haven't been touched in 60 days.
        planStore.archiveInactiveProjectScopes()
        // Wire the vision proxy service to the live inference engine.
        visionProxyService.setEngine(engine)
        // Expose the live-todo store to the native todo tools.
        MaestroTools.todoStore = todoStore
        // Expose the OSINT profile store to the native OSINT tools.
        MaestroTools.osintProfileStore = osintProfileStore
        // Expose the plan store to the native plan tools.
        MaestroTools.planStore = planStore
        // Expose the inter-agent message store to the messaging tools.
        MaestroTools.messageStore = messageStore
        // Expose the workspace layout so tools can open/focus panels.
        MaestroTools.workspaceLayout = WorkspaceLayoutState.shared
        // Wire client-side MCP tools into the inference engine and spawn the
        // user-enabled MCP servers (permissioned by MCP flags).
        engine.mcpService = mcpService
        await mcpService.startEnabledServers()
        // Expose the inference engine and model catalog so tools can run
        // headless agent workflows without coupling to the UI.
        MaestroTools.engine = engine
        MaestroTools.catalog = catalog
        // Create the persistent bus worker service and keep it alive.
        // `MaestroTools.busWorker` is weak, so the bootstrap holder owns it.
        let worker = BusWorker(engine: engine, mcpService: mcpService)
        WorkspaceBootstrap.shared.retain(worker)
        MaestroTools.busWorker = worker
        // System health watchdog: crash/hang notifications → "Diagnose with
        // Maestro" seeds the Navigator chat with the crash context.
        SystemHealthWatchService.shared.onDiagnose = { summary in
            let navigator = workspace.navigator
            let model = catalog.effectiveModel(for: navigator)
            let vm = ChatViewModelCache.shared.viewModel(
                for: navigator,
                projectName: workspace.projectName(for: navigator))
            vm.inputText = SystemHealthWatchService.diagnosticPrompt(for: summary)
            // Privacy gate: auto-send only to local models; a remote provider
            // gets a pre-filled draft the user reviews first (crash reports
            // can contain paths and usernames).
            if let model, !model.isRemote {
                vm.send(engine: engine, catalog: catalog, model: model)
            }
            WorkspaceCoordinator.shared.openPanel(.agentChat(navigator.id))
        }
        SystemHealthWatchService.shared.start()
        // Ensure the SwiftHelper support agent exists, and once the bundled
        // Qwen3-4B is on disk, default the SwiftHelper to it.
        let swiftHelper = workspace.swiftHelper
        if swiftHelper.modelID == nil, ModelCatalog.swiftHelperModelAvailable {
            workspace.setModel(ModelCatalog.swiftHelperModelID, for: swiftHelper.id)
        }
        // Ensure the bundled local coding agent exists, and once the coding
        // model is on disk, default the Local Coder to it.
        let coder = workspace.coder
        if coder.modelID == nil, ModelCatalog.coderModelAvailable {
            workspace.setModel(ModelCatalog.coderModelID, for: coder.id)
        }
        // Ensure the online coding agent exists. It intentionally has no
        // default model — the user selects a remote model.
        _ = workspace.onlineCoder
        // Ensure the built-in Searcher agent exists for fast search.
        _ = workspace.searcher
        // Ensure the built-in OSINT agent exists and default it to the
        // abliterated Gemma 4 26B-A4B OSINT model when it is on disk.
        let osint = workspace.osintAgent
        if osint.modelID == nil,
           ModelCatalog.builtInModels.first(where: { $0.id == "local-gemma4-26b-a4b-osint" })?.hasCompleteLocalWeights == true {
            workspace.setModel("local-gemma4-26b-a4b-osint", for: osint.id)
        }
        // Developer machines: give the SwiftHelper the SwiftMaestro repo as
        // its working directory so git history + docs/ are authorized tool
        // scope. End users keep the default app-support root.
        if swiftHelper.workingDirectory == nil {
            let repo = NSHomeDirectory() + "/GitHub/FUSV/SwiftMaestro"
            if FileManager.default.fileExists(atPath: repo + "/.git") {
                workspace.setWorkingDirectory(repo, for: swiftHelper.id)
            }
        }
        // Developer machines: give the Online Coder the SwiftMaestro repo as
        // its working directory so it can build and edit the project out of
        // the box. End users keep the default app-support root.
        if workspace.onlineCoder.workingDirectory == nil {
            let repo = NSHomeDirectory() + "/GitHub/FUSV/SwiftMaestro"
            if FileManager.default.fileExists(atPath: repo + "/.git") {
                workspace.setWorkingDirectory(repo, for: workspace.onlineCoder.id)
            }
        }
        // Validate capabilities for every locally-present model so tool-call
        // format / thinking support are known before any generation runs.
        await catalog.refreshCapabilities()
        // NOTE: We no longer eagerly auto-load the selected default model at
        // launch — MLX model-load failures can call fatalError() from C++ and
        // crash the app before the UI is usable. The first user message loads
        // the model on demand.
        whisper.notesVaultURL = notesViewModel.vaultURL
        whisper.ensureModelLoaded()
        // Voice Notes: wire the transcription + Notes.md export services
        // (also kicks off any recovered/queued notes).
        VoiceNotesStore.shared.attach(whisper: whisper, notesVault: notesViewModel.vaultURL)
        // Snapshot all user settings to ~/.config/SwiftMaestro/ so they
        // survive plist deletion and can be synced via Chezmoi.
        SettingsBackupService.shared.backup()
    }
}
