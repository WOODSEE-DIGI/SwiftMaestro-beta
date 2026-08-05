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
    @State private var chatCache = ChatViewModelCache()
    @State private var newProjectName = ""
    @State private var newAgentName = ""
    @State private var newAgentCategory: AgentCategory = .general
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

    private enum ActiveSheet: Identifiable {
        case newAgent
        case onboarding
        case welcome
        case whisperSetup
        case notesOnboarding
        case agentCategory(AgentRecord)

        var id: Int {
            switch self {
            case .newAgent: return 1
            case .onboarding: return 2
            case .welcome: return 0
            case .whisperSetup: return 3
            case .notesOnboarding: return 4
            case .agentCategory(let agent): return 5 + agent.id.hashValue
            }
        }
    }

    var body: some View {
        @Bindable var catalog = catalog

        TilingWorkspaceView()
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                    Text("Default").font(.caption).foregroundStyle(.secondary)
                    Picker("Default model", selection: $catalog.selectedModelID) {
                        ForEach(catalog.models) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)
                }
                .help("Global default model — used by any agent whose model is set to “Default (global)”.")
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
                OnboardingView(onDone: { onboardingSeen = true; activeSheet = nil })
                    .environment(catalog)
                    .environment(engine)
            case .welcome:
                WelcomeView(onDone: { welcomeSeen = true; activeSheet = nil })
                    .environment(catalog)
                    .environment(engine)
            case .whisperSetup:
                WhisperKitSetupSheet(onDone: { whisperKitSeen = true; activeSheet = nil })
                    .environment(whisper)
            case .notesOnboarding:
                NotesOnboardingSheet(onDone: { activeSheet = nil })
            case .agentCategory(let agent):
                agentCategorySheet(for: agent)
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
            // ChatViewModelCache.shared is set by its own init() now (see that
            // type's doc comment) — it must be valid before this view's very
            // first body evaluation, which is earlier than .onAppear ever runs.
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
            // Welcome screen: shown once before model selection.
            if !welcomeSeen && activeSheet == nil {
                activeSheet = .welcome
            }
            // Welcome a fresh install (no model files on disk yet), once.
            if welcomeSeen && !onboardingSeen && !catalog.models.contains(where: { $0.localPath != nil }) {
                activeSheet = .onboarding
            }
        }
        .task {
            // Prime every agent's inbox from disk so sidebar unread badges are
            // accurate at launch (not just for the open agent).
            for agent in workspace.agents { _ = messageStore.inbox(for: agent.id) }
            // Show WhisperKit setup dialog once when the model needs downloading.
            // Deferred until after onboarding so the sheets don't stack.
            if !whisperKitSeen && activeSheet == nil {
                if whisper.modelState == .loaded || whisper.isModelDownloaded {
                    // Already ready — mark seen so we never show the dialog again
                    whisperKitSeen = true
                } else if whisper.modelState == .unloaded {
                    // Not yet started — kick off the download, then present the sheet
                    whisper.ensureModelLoaded()
                    try? await Task.sleep(for: .milliseconds(500))
                    if activeSheet == nil { activeSheet = .whisperSetup }
                } else {
                    // Download/load already in progress (started by SwiftMaestroApp) —
                    // just show the sheet so the user can see progress.
                    if activeSheet == nil { activeSheet = .whisperSetup }
                }
            }
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

    private func removeAgent(_ agent: AgentRecord) {
        let kind = WorkspacePanelKind.agentChat(agent.id)
        workspace.archiveAgent(id: agent.id)
        chatCache.drop(agent.id)
        workspaceLayout.close(kind)
        // Never leave the workspace fully empty — land back on Maestro.
        if workspaceLayout.root == nil && workspaceLayout.floatingPanels.isEmpty {
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

    /// Shared instance accessible from static methods for delegate streaming.
    nonisolated(unsafe) static var shared: ChatViewModelCache?
    /// Called on the main actor when a delegation to `agentID` begins, so the UI
    /// can open or front a floating chat window for that sub-agent.
    var onOpenAgentWindow: ((UUID) -> Void)?

    /// Self-registers on construction rather than relying on a caller to set
    /// `shared` later (previously done in ContentView's `.onAppear`). That was
    /// a real race: any `.agentChat` panel already persisted/docked from a
    /// prior session renders as part of ContentView's very FIRST body
    /// evaluation, which unavoidably happens before `.onAppear` fires —
    /// `WorkspacePanelContentView` would see `shared == nil` on that first
    /// paint and permanently show "Agent Not Found" for the rest of the
    /// session, since mutating a plain static var later never triggers
    /// SwiftUI to re-render the already-mounted view (it isn't
    /// `@Observable`-tracked). Floating panel windows opened via a fresh
    /// `openWindow(...)` call happened to dodge this because constructing a
    /// new window scene takes measurably longer than the few CPU cycles
    /// between `@State private var chatCache = ChatViewModelCache()`'s
    /// construction and `.onAppear` firing — enough of a head start that
    /// `shared` was usually already set by the time THAT content rendered,
    /// which is why the bug was intermittent (docked panels: broken;
    /// floating windows: usually fine) rather than 100% reproducible.
    /// Self-registering in `init` removes the timing dependency entirely:
    /// `shared` is valid the instant the object exists, before ANY view
    /// (docked or floating) gets a chance to render.
    init() {
        Self.shared = self
    }

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
