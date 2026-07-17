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
    @Environment(\.openWindow) private var openWindow
    /// The multi-panel workspace: the sidebar is a *launcher* onto this — an
    /// agent chat, Notes.md, Apple Notes, Contacts, etc. can all be open side
    /// by side at once instead of one screen replacing another.
    @State private var workspaceLayout = WorkspaceLayoutState.shared
    /// Which sidebar row is currently highlighted. Decoupled from what's
    /// actually open in `workspaceLayout` — selecting a row opens/focuses
    /// that panel, but closing a panel via its own × doesn't have to change
    /// this highlight.
    @State private var focusedKind: WorkspacePanelKind?
    /// Per-agent chat view-models, kept alive so switching agents preserves the
    /// in-flight view state (history itself is persisted by ChatHistoryStore).
    @State private var chatCache = ChatViewModelCache()
    @State private var newProjectName = ""
    @State private var newAgentName = ""
    /// First-run welcome: shown once, only when no models are present on disk.
    @AppStorage("onboarding.seenV1") private var onboardingSeen = false
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
        case whisperSetup
        case notesOnboarding
        var id: Int { hashValue }
    }

    var body: some View {
        @Bindable var catalog = catalog

        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
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
        }
        .frame(minWidth: 900, minHeight: 620)
        .tint(theme.accent)
        .preferredColorScheme(theme.appearance.colorScheme)
        #if os(macOS)
        .background(
            WindowSizeConfigurator(
                minSize: CGSize(width: 900, height: 620),
                defaultSize: CGSize(width: 1100, height: 760)
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
            case .whisperSetup:
                WhisperKitSetupSheet(onDone: { whisperKitSeen = true; activeSheet = nil })
                    .environment(whisper)
            case .notesOnboarding:
                NotesOnboardingSheet(onDone: { activeSheet = nil })
            }
        }
        .onChange(of: focusedKind) { _, newValue in
            guard let newValue else { return }
            openPanel(newValue)
        }
        .onAppear {
            if workspaceLayout.rows.isEmpty && workspaceLayout.floatingPanels.isEmpty {
                openPanel(.agentChat(workspace.navigator.id))
            }
            // Explicitly (re)present every panel that was floating when the
            // app last quit, rather than relying on macOS to automatically
            // restore data-driven WindowGroup windows — that restoration
            // isn't guaranteed, and when it doesn't happen the persisted
            // state and reality silently disagree: the sidebar shows a panel
            // as "open" with no window to show for it, and clicking it does
            // nothing (`open(_:)` no-ops on an already-open kind). Doing this
            // explicitly keeps state and reality in sync unconditionally.
            for kind in workspaceLayout.floatingPanels {
                openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
            }
            if focusedKind == nil { focusedKind = workspaceLayout.allOpenPanels.first }
            // Set shared instance for delegate streaming.
            ChatViewModelCache.shared = chatCache
            chatCache.setVisionProxyService(visionProxyService)
            // When a delegation starts, open/front a floating chat window for the
            // sub-agent so the user can watch Navigator and Scribe side-by-side.
            chatCache.onOpenAgentWindow = { [openWindow] agentID in
                openWindow(id: "agent-chat-window", value: AgentChatWindowID(agentID: agentID))
            }
            // Welcome a fresh install (no model files on disk yet), once.
            if !onboardingSeen && !catalog.models.contains(where: { $0.localPath != nil }) {
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
            // Notes iCloud onboarding: prompt once, after other first-run sheets.
            if !notesOnboardingSeen && activeSheet == nil {
                if NotesiCloudSupport.onboardingChoiceMade {
                    notesOnboardingSeen = true
                } else {
                    activeSheet = .notesOnboarding
                }
            }
        }
    }

    // MARK: - Sidebar (Agents / Apps / Loaded)

    private var sidebar: some View {
        VStack(spacing: 0) {
            agentsSidebar
                .frame(minHeight: 120, maxHeight: .infinity)

            Divider()
                .padding(.horizontal, 8)

            appsSidebar
                .frame(minHeight: 120, maxHeight: .infinity)

            Divider()
                .padding(.horizontal, 8)

            loadedAgentsPanel
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .navigationTitle("SwiftMaestro")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { activeSheet = .newAgent } label: {
                    Image(systemName: "plus")
                }
                .help("New project agent")
            }
        }
    }

    private var agentsSidebar: some View {
        List(selection: $focusedKind) {
            Section("Agents") {
                agentRow(
                    title: workspace.navigator.name,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    id: workspace.navigator.id
                )
                .tag(WorkspacePanelKind.agentChat(workspace.navigator.id))
            }
            ForEach(workspace.projects) { project in
                Section(project.name) {
                    ForEach(workspace.projectAgents(in: project.id)) { agent in
                        agentRow(title: agent.name, systemImage: nil, id: agent.id)
                            .tag(WorkspacePanelKind.agentChat(agent.id))
                            .contextMenu {
                                Button("Clear Chat") {
                                    chatCache.viewModel(for: agent, projectName: project.name)
                                        .clearChat()
                                }
                                Button("Remove Agent", role: .destructive) {
                                    removeAgent(agent)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(theme.sidebarOverridden ? .hidden : .automatic)
        .background(theme.sidebarOverridden ? theme.sidebarBackground : Color.clear)
    }

    private var appsSidebar: some View {
        List(selection: $focusedKind) {
            Section("Apple Apps") {
                sidebarRow("Apple Notes", kind: .appleNotes)
                sidebarRow("Calendar", kind: .calendar)
                sidebarRow("Reminders", kind: .reminders)
                sidebarRow("Contacts", kind: .contacts)
            }
            Section("Swift Apps") {
                sidebarRow("Notes.md", kind: .notesMD)
                sidebarRow("Canvas", kind: .canvas)
                sidebarRow("Kanban", kind: .kanban)
                sidebarRow("Terminal", kind: .terminal)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(theme.sidebarOverridden ? .hidden : .automatic)
        .background(theme.sidebarOverridden ? theme.sidebarBackground : Color.clear)
    }

    /// A non-agent sidebar row. Shows a small filled dot when the panel is
    /// currently open in the workspace, since with multiple panels open at
    /// once the row highlight alone no longer tells you what's visible.
    private func sidebarRow(_ title: String, kind: WorkspacePanelKind) -> some View {
        HStack {
            Label(title, systemImage: kind.icon)
            Spacer()
            if workspaceLayout.isOpen(kind) {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .tag(kind)
    }

    private var loadedAgentsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Loaded Agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ModelResourceMonitor()
            ProcessResourceMonitor()
            EngineStatusBar()
        }
    }

    /// A sidebar agent row showing its name plus a red unread-message badge.
    @ViewBuilder
    private func agentRow(title: String, systemImage: String?, id: UUID) -> some View {
        let isSelected = focusedKind == .agentChat(id)
        let isOpen = workspaceLayout.isOpen(.agentChat(id))
        HStack {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            // Selected rows keep the system's white-on-accent highlight; others
            // use the themed sidebar text (default `.primary`, full brightness)
            // instead of the muted vibrant sidebar label.
            .foregroundStyle(isSelected ? Color.white : theme.sidebarText)
            Spacer()
            let unread = (messageStore.inboxes[id] ?? []).filter { !$0.read }.count
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.red))
            } else if isOpen {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Workspace (multi-panel, multi-row detail area)

    @ViewBuilder
    private var detail: some View {
        if workspaceLayout.rows.isEmpty {
            ContentUnavailableView(
                "Select an Item",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Choose an agent or app from the sidebar to open it")
            )
        } else {
            // A vertical host of rows, each row itself a horizontal host of
            // columns — a genuine 2-D tiling grid ("quadrants") rather than a
            // single endlessly-shrinking horizontal strip. Track the measured
            // width so `WorkspaceLayoutState.open(_:)` can Tetris-place new
            // panels into the current row only when they'd actually fit.
            GeometryReader { proxy in
                ResizablePanelHost(axis: .vertical, panes: rowPanes)
                    .onAppear { workspaceLayout.updateAvailableWidth(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, newValue in
                        workspaceLayout.updateAvailableWidth(newValue)
                    }
            }
        }
    }

    /// One resizable (vertical) pane per row. Every row is drag-resizable
    /// except the last, which is always flexible and fills remaining height.
    private var rowPanes: [ResizablePane] {
        let rows = workspaceLayout.rows
        return rows.enumerated().map { index, row in
            let isLast = index == rows.count - 1
            return ResizablePane(
                id: row.id,
                length: isLast ? nil : workspaceLayout.heightBinding(for: row),
                minLength: 200,
                maxLength: 1_400
            ) {
                ResizablePanelHost(axis: .horizontal, panes: columnPanes(for: row))
            }
        }
    }

    /// One resizable (horizontal) pane per panel within a single row. Every
    /// column is drag-resizable except the last, which is always flexible —
    /// matching `ResizablePanelHost`'s "fixed panes + one trailing flexible
    /// pane" contract.
    private func columnPanes(for row: WorkspaceRow) -> [ResizablePane] {
        row.panels.enumerated().map { index, kind in
            let isLast = index == row.panels.count - 1
            return ResizablePane(
                id: kind,
                length: isLast ? nil : workspaceLayout.widthBinding(for: kind),
                minLength: kind.minColumnWidth,
                maxLength: 1_400
            ) {
                WorkspacePanelContainer(kind: kind, title: title(for: kind), content: {
                    panelContent(for: kind)
                }, onFloat: { kind in
                    openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
                })
            }
        }
    }

    private func title(for kind: WorkspacePanelKind) -> String {
        if case .agentChat(let id) = kind {
            return workspace.agent(id: id)?.name ?? "Agent"
        }
        return kind.staticDisplayName ?? "Panel"
    }

    private func panelContent(for kind: WorkspacePanelKind) -> some View {
        WorkspacePanelContentView(kind: kind)
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

    /// Opens a panel via `workspaceLayout`, and — if it opened as a floating
    /// window rather than docking directly — actually presents that window.
    /// The single call site every "open this panel" action should go through.
    private func openPanel(_ kind: WorkspacePanelKind) {
        let result = workspaceLayout.open(kind)
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
        case .dockedDirectly:
            break
        }
    }

    private func createAgent() {
        let created = workspace.createProjectAgent(
            projectName: newProjectName.trimmingCharacters(in: .whitespaces),
            agentName: newAgentName.trimmingCharacters(in: .whitespaces)
        )
        let kind = WorkspacePanelKind.agentChat(created.id)
        openPanel(kind)
        focusedKind = kind
        resetNewAgent()
    }

    private func resetNewAgent() {
        newProjectName = ""
        newAgentName = ""
        activeSheet = nil
    }

    private func removeAgent(_ agent: AgentRecord) {
        let kind = WorkspacePanelKind.agentChat(agent.id)
        workspace.archiveAgent(id: agent.id)
        chatCache.drop(agent.id)
        workspaceLayout.close(kind)
        // Never leave the workspace fully empty — land back on Navigator.
        if workspaceLayout.rows.isEmpty && workspaceLayout.floatingPanels.isEmpty {
            let navigatorKind = WorkspacePanelKind.agentChat(workspace.navigator.id)
            openPanel(navigatorKind)
            focusedKind = navigatorKind
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
    func appendToken(_ token: String, toAgentID agentID: UUID) {
        guard let vm = byID[agentID] else { return }
        vm.objectWillChange.send()
        if vm.messages.last?.role == .assistant {
            // Re-strip the entire accumulated content each token so tags that span
            // token boundaries or appear in different forms still get removed.
            let accumulated = vm.messages[vm.messages.count - 1].content + token
            let cleaned = Self.stripThinkingTags(accumulated)
            vm.messages[vm.messages.count - 1].content = cleaned
        }
    }

    /// Strip XML thinking/channel tags from a string.
    /// Delegates to the shared stripper so all layers use the same patterns.
    private static func stripThinkingTags(_ text: String) -> String {
        ThinkingTagStripper.strip(text)
    }

    /// Notify an agent that delegation started (append empty assistant message).
    func beginDelegation(forAgentID agentID: UUID) {
        guard let vm = byID[agentID] else { return }
        vm.objectWillChange.send()
        vm.messages.append(Message(role: .assistant, content: ""))
        onOpenAgentWindow?(agentID)
    }

    /// Reload an agent's messages from the persisted exchange after delegation.
    @MainActor
    func reloadMessages(forAgentID agentID: UUID, messages: [Message]) {
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
        guard let vm = byID[agentID] else { return }
        vm.persistHistory()
    }
}
