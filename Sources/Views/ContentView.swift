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
    /// Sidebar selection can be an agent chat, an Apple app, or a SwiftMaestro app.
    private enum SidebarItem: Hashable {
        case agent(UUID)
        case notesMD
        case appleNotes
        case calendar
        case reminders
        case contacts
        case canvas
        case kanban
    }
    @State private var selectedItem: SidebarItem?
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
        .onAppear {
            if selectedItem == nil { selectedItem = .agent(workspace.navigator.id) }
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
        List(selection: $selectedItem) {
            Section("Agents") {
                agentRow(
                    title: workspace.navigator.name,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    id: workspace.navigator.id
                )
                .tag(SidebarItem.agent(workspace.navigator.id))
            }
            ForEach(workspace.projects) { project in
                Section(project.name) {
                    ForEach(workspace.projectAgents(in: project.id)) { agent in
                        agentRow(title: agent.name, systemImage: nil, id: agent.id)
                            .tag(SidebarItem.agent(agent.id))
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
        List(selection: $selectedItem) {
            Section("Apple Apps") {
                Label("Apple Notes", systemImage: "note.text")
                    .tag(SidebarItem.appleNotes)
                Label("Calendar", systemImage: "calendar")
                    .tag(SidebarItem.calendar)
                Label("Reminders", systemImage: "checklist")
                    .tag(SidebarItem.reminders)
                Label("Contacts", systemImage: "person.2")
                    .tag(SidebarItem.contacts)
            }
            Section("Swift Apps") {
                Label("Notes.md", systemImage: "doc.text")
                    .tag(SidebarItem.notesMD)
                Label("Canvas", systemImage: "rectangle.3.group")
                    .tag(SidebarItem.canvas)
                Label("Kanban", systemImage: "rectangle.split.3x1")
                    .tag(SidebarItem.kanban)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(theme.sidebarOverridden ? .hidden : .automatic)
        .background(theme.sidebarOverridden ? theme.sidebarBackground : Color.clear)
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
        let isSelected = selectedItem == .agent(id)
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
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedItem {
        case .notesMD:
            NotesView(viewModel: notesViewModel)
        case .appleNotes:
            AppleNotesView()
        case .calendar:
            CalendarView()
        case .reminders:
            RemindersView()
        case .contacts:
            ContactsView()
        case .canvas:
            if #available(macOS 26.0, *) {
                CanvasView()
            } else {
                CanvasFallbackView()
            }
        case .kanban:
            KanbanView()
        case .agent(let id):
            if let agent = workspace.agent(id: id) {
                ChatView(vm: chatCache.viewModel(
                    for: agent,
                    projectName: workspace.projectName(for: agent)))
                    .id(agent.id)
                    .toolbar {
                        ToolbarItem(placement: .destructiveAction) {
                            Button {
                                chatCache.viewModel(
                                    for: agent,
                                    projectName: workspace.projectName(for: agent)
                                ).clearChat()
                            } label: {
                                Label("Clear Chat", systemImage: "eraser")
                            }
                            .help("Clear this chat (keeps project memory)")
                        }
                    }
            } else {
                ContentUnavailableView(
                    "Agent Not Found",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("The selected agent no longer exists")
                )
            }
        case .none:
            ContentUnavailableView(
                "Select an Item",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Choose an agent or app from the sidebar")
            )
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

    private func createAgent() {
        let created = workspace.createProjectAgent(
            projectName: newProjectName.trimmingCharacters(in: .whitespaces),
            agentName: newAgentName.trimmingCharacters(in: .whitespaces)
        )
        selectedItem = .agent(created.id)
        resetNewAgent()
    }

    private func resetNewAgent() {
        newProjectName = ""
        newAgentName = ""
        activeSheet = nil
    }

    private func removeAgent(_ agent: AgentRecord) {
        let wasSelected = selectedItem == .agent(agent.id)
        workspace.archiveAgent(id: agent.id)
        chatCache.drop(agent.id)
        if wasSelected { selectedItem = .agent(workspace.navigator.id) }
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
