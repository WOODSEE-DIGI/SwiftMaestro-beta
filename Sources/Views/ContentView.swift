import SwiftUI

struct ContentView: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(VisionProxyService.self) private var visionProxyService
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(ThemeStore.self) private var theme
    @Environment(WhisperKitService.self) private var whisper
    @Environment(NotesViewModel.self) private var notesViewModel
    @Environment(KanbanStore.self) private var kanbanStore
    @Environment(ContactsService.self) private var contactsService
    @Environment(PluginService.self) private var pluginService
    @Environment(DiscordService.self) private var discordService
    @Environment(\.openWindow) private var openWindow
    /// The multi-panel workspace: the sidebar is a *launcher* onto this — an
    /// agent chat, Notes.md, Apple Notes, Contacts, etc. can all be open side
    /// by side at once instead of one screen replacing another.
    @State private var workspaceLayout = WorkspaceLayoutState.shared
    /// Per-agent chat view-models, kept alive so switching agents preserves the
    /// in-flight view state (history itself is persisted by ChatHistoryStore).
    @State private var chatCache = ChatViewModelCache.shared
    @State private var newProjectName = ""
    @State private var newAgentName = ""
    @State private var newAgentCategory: AgentCategory = .general
    @State private var newPresetName = ""
    @State private var newPresetSlot = 1
    /// First-run welcome: shown once, only when no models are present on disk.
    @AppStorage("onboarding.seenV1") private var onboardingSeen = false
    /// Welcome screen: shown once before onboarding on first launch.
    @AppStorage("welcome.seenV1") private var welcomeSeen = false
    /// WhisperKit first-run: shown once when the speech model needs downloading.
    @AppStorage("whisperkit.seenV1") private var whisperKitSeen = false
    /// Notes iCloud sync first-run: shown once so new users can confirm sync.
    @AppStorage("notes.icloudOnboardingSeen") private var notesOnboardingSeen = false
    /// The single active modal sheet. SwiftUI only honours ONE `.sheet`
    /// modifier per view; stacking two (new-agent + onboarding) silently drops
    /// one, which previously suppressed the first-run model picker. Driving a
    /// single `.sheet(item:)` from this enum guarantees both can present.
    @State private var activeSheet: ActiveSheet?
    /// First-run dependency install progress (planned pre-UI by the
    /// AppDelegate). Drives the setup sheet that replaces the beachball.
    @State private var setupProgress = SetupProgressService.shared
    /// True once the setup sheet has been presented this launch — the user can
    /// background it without the chain re-presenting it.
    @State private var setupSheetHandled = false

    private enum ActiveSheet: Identifiable {
        case newAgent
        case onboarding
        case welcome
        case setup
        case whisperSetup
        case notesOnboarding
        case agentCategory(AgentRecord)
        case diagnosticReport(description: String, mediaPath: String)
        case savePreset

        var id: Int {
            switch self {
            case .newAgent: return 1
            case .onboarding: return 2
            case .welcome: return 0
            case .setup: return 6
            case .whisperSetup: return 3
            case .notesOnboarding: return 4
            case .agentCategory(let agent): return 5 + agent.id.hashValue
            case .diagnosticReport: return 7
            case .savePreset: return 8
            }
        }
    }

    var body: some View {
        @Bindable var catalog = catalog

        CanvasWorkspaceView(canvasID: CanvasTile.mainCanvasID)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                WorkspaceSwitcherView()
            }
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                    Text("Default").font(.caption).foregroundStyle(.secondary)
                    // Menu with a custom label: toolbar pickers don't render
                    // custom Label content in the closed state (the text
                    // vanished), so the label is drawn explicitly here.
                    Menu {
                        ForEach(catalog.models) { model in
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
                    .frame(maxWidth: 220)
                }
                .help("Global default model — used by any agent whose model is set to “Default (global)”.")
            }
            ToolbarItem(placement: .principal) {
                // Omarchy-style top-center pomodoro clock: hover for info,
                // left-click opens the dashboard panel, right-click for controls.
                PomodoroTitleBarTimer(store: PomodoroStore.shared) {
                    openPanel(.pomodoro)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    activeSheet = .newAgent
                } label: {
                    Image(systemName: "plus")
                }
                .help("New project agent")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // Saved presets
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
                        activeSheet = .savePreset
                    }
                    Button("Reset to Default") {
                        workspaceLayout.resetToDefaultLayout()
                    }
                } label: {
                    Image(systemName: "rectangle.grid.2x2")
                }
                .help("Workspace layouts — save, recall, or reset")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspaceLayout.cycleLayoutAlgorithm()
                } label: {
                    Image(systemName: workspaceLayout.layoutAlgorithm.icon)
                }
                .help("Layout: \(workspaceLayout.layoutAlgorithm.displayName) — click to cycle")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    workspaceLayout.isLocked.toggle()
                } label: {
                    Image(systemName: workspaceLayout.isLocked ? "lock" : "lock.open")
                    Text(workspaceLayout.isLocked ? "Locked" : "Unlocked")
                }
                .help(workspaceLayout.isLocked
                    ? "Workspace is locked — panels cannot be dragged"
                    : "Workspace is unlocked — drag the grip to rearrange panels")
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .tint(theme.accent)
        .preferredColorScheme(theme.appearance.colorScheme)
        // (No scheme bridging needed — ThemeStore drives NSApp.appearance
        // itself, making `.system` resolution deterministic.)
        #if os(macOS)
        .background(
            WindowSizeConfigurator(
                minSize: CGSize(width: 900, height: 620),
                defaultSize: CGSize(width: 1100, height: 760),
                backgroundColor: nil
            )
        )
        #endif
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newAgent:
                newAgentSheet
            case .onboarding:
                OnboardingView(onDone: { onboardingSeen = true; activeSheet = nil; advanceFirstRunSheets() })
                    .environment(catalog)
                    .environment(engine)
            case .diagnosticReport(let description, let mediaPath):
                DiagnosticReportView(initialDescription: description, initialMediaPath: mediaPath)
            case .diagnosticReport(let description, let mediaPath):
                DiagnosticReportView(initialDescription: description, initialMediaPath: mediaPath)
            case .welcome:
                WelcomeView(onDone: { welcomeSeen = true; activeSheet = nil; advanceFirstRunSheets() })
                    .environment(catalog)
                    .environment(engine)
            case .setup:
                SetupProgressView(
                    onContinueInBackground: {
                        activeSheet = nil
                        advanceFirstRunSheets()
                    },
                    onFinished: {
                        activeSheet = nil
                        advanceFirstRunSheets()
                    }
                )
            case .whisperSetup:
                WhisperKitSetupSheet(onDone: { whisperKitSeen = true; activeSheet = nil })
                    .environment(whisper)
            case .notesOnboarding:
                NotesOnboardingSheet(onDone: { activeSheet = nil })
            case .agentCategory(let agent):
                agentCategorySheet(for: agent)
            case .savePreset:
                savePresetSheet
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkspacePanel)) { notification in
            guard let kind = notification.object as? WorkspacePanelKind else { return }
            // Read modifier flags captured at click time (passed via userInfo
            // by AppsLauncherPanel) so we don't race against key release.
            let flags: NSEvent.ModifierFlags = {
                if let stored = notification.userInfo?["modifierFlags"] as? NSEvent.ModifierFlags {
                    return stored
                }
                return NSEvent.modifierFlags
            }()
            // Shift → dock below (new row); Option → float; default → dock right.
            let zone: TilingDropZone? = flags.contains(.option) ? nil
                : flags.contains(.shift) ? .bottom
                : .right
            openPanel(kind, zone: zone)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDiagnosticReport)) { notification in
            let description = notification.userInfo?["description"] as? String ?? ""
            let mediaPath = notification.userInfo?["mediaPath"] as? String ?? ""
            activeSheet = .diagnosticReport(description: description, mediaPath: mediaPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newAgentRequested)) { _ in
            activeSheet = .newAgent
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentCategoryRequested)) { notification in
            guard let agent = notification.object as? AgentRecord else { return }
            activeSheet = .agentCategory(agent)
        }
        .onReceive(NotificationCenter.default.publisher(for: .removeAgentRequested)) { notification in
            guard let agent = notification.object as? AgentRecord else { return }
            removeAgent(agent)
        }
        .onAppear {
            workspaceLayout.ensureChromeLayout(navigatorID: workspace.navigator.id)
            // Explicitly (re)present every panel that was floating when the
            // app last quit, rather than relying SOLELY on macOS to
            // automatically restore data-driven WindowGroup windows — that
            // restoration isn't guaranteed, and when it doesn't happen the
            // persisted state and reality silently disagree: the sidebar
            // shows a panel as "open" with no window to show for it, and
            // clicking it does nothing (`open(_:)` no-ops on an already-open
            // kind). Doing this explicitly keeps state and reality in sync
            // unconditionally.
            //
            // BUT: firing this unconditionally in the SAME .onAppear pass
            // (rather than after a short delay) raced macOS's own
            // restoration — confirmed live: a panel macOS DID successfully
            // restore (correct saved position, correct Space) ALSO got a
            // second, brand-new window from this loop (default size,
            // whatever Space happened to be active), because `openWindow`
            // can only dedup against a window it already knows exists at the
            // moment it's called, and system restoration hadn't finished
            // registering its window yet. Window restoration is effectively
            // instantaneous once it happens at all, so this delay is free
            // for the case restoration doesn't apply, while avoiding the
            // race for the case it does.
            Task {
                try? await Task.sleep(for: .seconds(1))
                for kind in workspaceLayout.floatingPanels {
                    openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
                }
            }
            // ChatViewModelCache.shared is a non-optional singleton (see that
            // type's doc comment) — always valid, even before this view's very
            // first body evaluation.
            chatCache.setVisionProxyService(visionProxyService)
            // When a delegation starts, open/front a floating chat window for the
            // sub-agent so the user can watch Maestro and Scribe side-by-side.
            // Use the tracked workspace-panel window so the sidebar can refocus it.
            chatCache.onOpenAgentWindow = { [openWindow] agentID in
                let kind = WorkspacePanelKind.agentChat(agentID)
                let result = WorkspaceLayoutState.shared.open(kind)
                if result == .dockedDirectly {
                    WorkspaceLayoutState.shared.float(kind)
                }
                openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
            }
            // First-run sheet chain: setup → welcome → onboarding → whisper.
            // `hasPendingWork` was planned pre-UI by the AppDelegate, so this
            // is deterministic — no sheet flicker.
            if activeSheet == nil {
                advanceFirstRunSheets()
            }
        }
        // If the speech model starts preparing while no first-run sheet is up
        // (e.g. the setup sheet just finished and the bundled Whisper copy is
        // now loading into memory), surface the explainer — first run only.
        .onChange(of: whisper.modelState) { _, newState in
            guard !whisperKitSeen, activeSheet == nil else { return }
            if newState == .downloading || newState == .loading || newState == .prewarming {
                activeSheet = .whisperSetup
            }
        }
        .task {
            // Prime every agent's inbox from disk so sidebar unread badges are
            // accurate at launch (not just for the open agent).
            for agent in workspace.agents { _ = messageStore.inbox(for: agent.id) }
            // Notes iCloud onboarding: already handled in WelcomeView.
            // Mark as seen so the old sheet never re-appears.
            if !notesOnboardingSeen && welcomeSeen {
                notesOnboardingSeen = true
            }
        }
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
                Button("Done") { activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
    }

    /// Advances the first-run sheet sequence: setup → welcome → onboarding →
    /// whisper. Each sheet's completion handler calls this to present the next
    /// one due; `.onAppear` kicks off the chain.
    ///
    /// The whisper step exists because first launch loads the speech model
    /// into memory (a slow first CoreML compile) with otherwise NO visible
    /// indication — the user just saw a "Loading model…" line buried in
    /// Settings. The sheet explains the wait and dismisses itself when ready.
    private func advanceFirstRunSheets() {
        // 1. Dependency setup (only when this launch actually installs things).
        if !setupSheetHandled && (setupProgress.hasPendingWork || setupProgress.isRunning) {
            setupSheetHandled = true
            activeSheet = .setup
            return
        }
        // 2. Welcome screen: shown once before model selection.
        if !welcomeSeen {
            activeSheet = .welcome
            return
        }
        // 3. Model picker for fresh installs (no model files on disk yet).
        if !onboardingSeen && !catalog.models.contains(where: { $0.localPath != nil }) {
            activeSheet = .onboarding
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
                activeSheet = .whisperSetup
            }
        }
    }

    /// Opens a panel via `workspaceLayout`, and — if it opened as a floating
    /// window rather than docking directly — actually presents that window.
    /// The single call site every "open this panel" action should go through.
    private func openPanel(_ kind: WorkspacePanelKind, zone: TilingDropZone? = .right) {
        let result = workspaceLayout.open(kind, zone: zone)
        switch result {
        case .floated:
            openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
        case .alreadyOpen:
            // Self-healing: if state says this panel is floating but its
            // window somehow doesn't actually exist anymore (e.g. state
            // restoration didn't recreate it, or a previous crash left things
            // out of sync), re-clicking it in the sidebar should still work
            // instead of silently doing nothing. `openWindow` is safe to call
            // even when a matching window already exists — it just brings
            // that window forward rather than duplicating it.
            if workspaceLayout.isFloating(kind) {
                openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
            }
            // Bring any open floating window for this panel to the front, and
            // also bring any detached agent-chat window to the front.
            NotificationCenter.default.post(name: .bringWorkspacePanelToFront, object: kind)
            if case .agentChat(let id) = kind {
                NotificationCenter.default.post(name: .bringAgentChatToFront, object: id)
            }
        case .dockedDirectly:
            break
        }
    }

    private func createAgent() {
        let created = workspace.createProjectAgent(
            projectName: newProjectName.trimmingCharacters(in: .whitespaces),
            agentName: newAgentName.trimmingCharacters(in: .whitespaces),
            category: newAgentCategory
        )
        let kind = WorkspacePanelKind.agentChat(created.id)
        openPanel(kind)
        resetNewAgent()
    }

    private func resetNewAgent() {
        newProjectName = ""
        newAgentName = ""
        newAgentCategory = .general
        activeSheet = nil
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
                Button("Cancel") { newPresetName = ""; activeSheet = nil }
                Button("Save") {
                    WorkspaceLayoutPresetStore.shared.saveToSlot(newPresetSlot, name: newPresetName)
                    newPresetName = ""
                    activeSheet = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func removeAgent(_ agent: AgentRecord) {
        let kind = WorkspacePanelKind.agentChat(agent.id)
        workspace.archiveAgent(id: agent.id)
        chatCache.drop(agent.id)
        workspaceLayout.close(kind)
        // Never leave the workspace fully empty — land back on Maestro.
        if workspaceLayout.canvasTiles.isEmpty && workspaceLayout.floatingPanels.isEmpty {
            let navigatorKind = WorkspacePanelKind.agentChat(workspace.navigator.id)
            openPanel(navigatorKind)
        }
    }
}

// MARK: - Engine Status Bar

struct EngineStatusBar: View {
    @Environment(MLXInferenceEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if engine.tokensPerSecond > 0 {
                    Text(String(format: "%.1f tok/s", engine.tokensPerSecond))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            if !engine.residentModelsReadout.isEmpty {
                ForEach(engine.residentModelsReadout) { model in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(model.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .help(model.name)
                        Spacer(minLength: 4)
                        Text("~\(model.gb) GB")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        switch engine.state {
        case .idle: return .gray
        case .loading: return .orange
        case .ready: return .green
        case .generating: return .blue
        case .downloading: return .cyan
        case .error: return .red
        }
    }

    private var statusText: String {
        switch engine.state {
        case .idle: return "Ready"
        case .loading(let name): return "Loading \(name)…"
        case .ready: return "Ready"
        case .generating: return "Generating…"
        case .downloading(let name): return name
        case .error(let msg): return msg
        }
    }
}

// MARK: - Chat view-model cache

/// Keeps one `ChatViewModel` per agent alive for the session so switching
/// agents preserves each conversation. Plain reference type (not observable):
/// mutating its cache during a view body does not trigger SwiftUI updates.
@MainActor
final class ChatViewModelCache {
    private var byID: [UUID: ChatViewModel] = [:]
    private var visionProxyService: VisionProxyService?

    /// The single shared cache for the whole process.
    ///
    /// This MUST be a non-optional lazily-initialized singleton. The previous
    /// design (`static var shared: ChatViewModelCache?` assigned from `init`)
    /// had two failure modes:
    ///  1. `shared == nil` during the first body evaluation (the original race
    ///     this type's init-self-registration was added to fix), and
    ///  2. worse: EVERY `ChatViewModelCache()` construction silently replaced
    ///     `shared`. ContentView's `@State` constructs one per main window, so
    ///     with multiple windows (or window-state restoration) `shared` flipped
    ///     to the newest window's EMPTY cache. Chat views kept their existing
    ///     VMs alive via `@StateObject`, but anything reaching for
    ///     `shared.viewModel(for:)` afterwards (Clear Chat, delegate streaming,
    ///     reloadMessages) minted a FRESH empty VM and mutated that phantom —
    ///     the on-screen conversation never changed. That is exactly the
    ///     "Clear Chat button does nothing" bug.
    /// A `static let` can never be nil, can never be replaced, and initializes
    /// synchronously on first access — all three problems gone.
    nonisolated static let shared = ChatViewModelCache()
    /// Called on the main actor when a delegation to `agentID` begins, so the UI
    /// can open or front a floating chat window for that sub-agent.
    var onOpenAgentWindow: ((UUID) -> Void)?

    /// Non-isolated so `static let shared` can initialize without hopping to the
    /// main actor. All stored properties have defaults; nothing actor-isolated
    /// is touched here.
    nonisolated init() {}

    func setVisionProxyService(_ service: VisionProxyService) {
        self.visionProxyService = service
    }

    func viewModel(for agent: AgentRecord, projectName: String?) -> ChatViewModel {
        if let existing = byID[agent.id] { return existing }
        let vm = ChatViewModel(
            agent: agent,
            projectName: projectName,
            visionProxyService: visionProxyService ?? VisionProxyService())
        byID[agent.id] = vm
        return vm
    }

    /// Drop a cached view-model (e.g. after archiving its agent).
    func drop(_ id: UUID) { byID[id] = nil }

    /// Append a token to an agent's current assistant message (for delegate streaming).
    /// Strips XML thinking/channel tags so the chat shows clean content.
    /// Tokens are buffered and flushed in small batches to avoid one SwiftUI
    /// update per token, which is the dominant source of "laggy" streaming.
    func appendToken(_ token: String, toAgentID agentID: UUID) {
        guard byID[agentID] != nil else { return }
        var buffer = tokenBuffers[agentID] ?? ""
        buffer += token
        tokenBuffers[agentID] = buffer

        let now = ContinuousClock.now
        let last = lastFlushTimes[agentID] ?? now
        let threshold = 50  // characters
        let interval: Duration = .milliseconds(50)
        let elapsed = last.duration(to: now)
        if buffer.count >= threshold || elapsed >= interval {
            flushTokens(for: agentID)
        }
    }

    /// Buffers of streaming tokens per agent, waiting to be flushed to the UI.
    private var tokenBuffers: [UUID: String] = [:]
    /// Last UI flush time per agent, so we can time-cap token buffering.
    private var lastFlushTimes: [UUID: ContinuousClock.Instant] = [:]

    /// Flush the buffered tokens for an agent into its last assistant message.
    /// This is the only place we mutate the UI and re-strip the accumulated
    /// content, so expensive tag stripping and SwiftUI re-renders happen once
    /// per batch instead of once per token.
    func flushTokens(for agentID: UUID) {
        guard let vm = byID[agentID],
              let buffer = tokenBuffers[agentID],
              !buffer.isEmpty else { return }
        tokenBuffers[agentID] = ""
        lastFlushTimes[agentID] = ContinuousClock.now

        vm.objectWillChange.send()
        if vm.messages.last?.role == .assistant {
            let idx = vm.messages.count - 1
            // Re-strip the entire accumulated content each flush so tags that span
            // token boundaries or appear in different forms still get removed.
            let accumulated = vm.messages[idx].content + buffer
            let cleaned = Self.stripThinkingTags(accumulated)
            vm.messages[idx].content = cleaned
            // Ensure the live streaming message carries metadata even if it was
            // created before the model name was resolved.
            if vm.messages[idx].modelName == nil || vm.messages[idx].modelName?.isEmpty == true {
                vm.messages[idx].modelName = ChatViewModel.effectiveDelegateModelNames[agentID.uuidString]
            }
        }
    }

    /// Strip XML thinking/channel tags from a string.
    /// Delegates to the shared stripper so all layers use the same patterns.
    private static func stripThinkingTags(_ text: String) -> String {
        ThinkingTagStripper.strip(text)
    }

    /// Notify an agent that delegation started (append empty assistant message).
    /// `modelName` is the resolved model running the sub-agent, shown in the footer.
    func beginDelegation(forAgentID agentID: UUID, modelName: String? = nil) {
        guard let vm = byID[agentID] else { return }
        vm.objectWillChange.send()
        vm.messages.append(Message(
            role: .assistant, content: "",
            timestamp: Date(), modelName: modelName))
        onOpenAgentWindow?(agentID)
    }

    /// Reload an agent's messages from the persisted exchange after delegation.
    @MainActor
    func reloadMessages(forAgentID agentID: UUID, messages: [Message]) {
        flushTokens(for: agentID)
        if let vm = byID[agentID] {
            vm.objectWillChange.send()
            vm.messages = messages
        } else {
            NSLog("[CACHE] reloadMessages: no VM for \(agentID) — creating fresh one")
            guard let agent = MaestroTools.workspace?.agent(id: agentID) else {
                NSLog("[CACHE] reloadMessages: can't find agent record for \(agentID)")
                return
            }
            let vm = ChatViewModel(
                agent: agent,
                projectName: MaestroTools.workspace?.projectName(for: agent),
                visionProxyService: visionProxyService ?? VisionProxyService())
            vm.messages = messages
            byID[agentID] = vm
        }
    }

    /// Check if a VM exists for an agent.
    func hasViewModel(for agentID: UUID) -> Bool {
        byID[agentID] != nil
    }

    /// Notify an agent that delegation finished (save history).
    func finishDelegation(forAgentID agentID: UUID) {
        flushTokens(for: agentID)
        guard let vm = byID[agentID] else { return }
        vm.persistHistory()
    }
}
