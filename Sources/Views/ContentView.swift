import SwiftUI

struct ContentView: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(ThemeStore.self) private var theme
    @State private var selectedAgentID: UUID?
    /// Per-agent chat view-models, kept alive so switching agents preserves the
    /// in-flight view state (history itself is persisted by ChatHistoryStore).
    @State private var chatCache = ChatViewModelCache()
    @State private var showingNewAgent = false
    @State private var newProjectName = ""
    @State private var newAgentName = ""
    /// First-run welcome: shown once, only when no models are present on disk.
    @AppStorage("onboarding.seenV1") private var onboardingSeen = false
    @State private var showOnboarding = false

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
        .sheet(isPresented: $showingNewAgent) { newAgentSheet }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(onDone: { onboardingSeen = true; showOnboarding = false })
                .environment(catalog)
                .environment(engine)
        }
        .onAppear {
            if selectedAgentID == nil { selectedAgentID = workspace.navigator.id }
            // Welcome a fresh install (no model files on disk yet), once.
            if !onboardingSeen && !catalog.models.contains(where: { $0.localPath != nil }) {
                showOnboarding = true
            }
        }
        .task {
            // Prime every agent's inbox from disk so sidebar unread badges are
            // accurate at launch (not just for the open agent).
            for agent in workspace.agents { _ = messageStore.inbox(for: agent.id) }
        }
    }

    // MARK: - Sidebar (Navigator + Projects → project agents)

    private var sidebar: some View {
        List(selection: $selectedAgentID) {
            Section("Navigator") {
                agentRow(
                    title: workspace.navigator.name,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    id: workspace.navigator.id
                )
                .tag(workspace.navigator.id)
            }
            ForEach(workspace.projects) { project in
                Section(project.name) {
                    ForEach(workspace.projectAgents(in: project.id)) { agent in
                        agentRow(title: agent.name, systemImage: nil, id: agent.id)
                            .tag(agent.id)
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
        .navigationTitle("SwiftMaestro")
        // Only replace the list's default material when the user set a custom
        // sidebar color; otherwise leave the system appearance untouched.
        .scrollContentBackground(theme.sidebarOverridden ? .hidden : .automatic)
        .background(theme.sidebarOverridden ? theme.sidebarBackground : Color.clear)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNewAgent = true } label: {
                    Image(systemName: "plus")
                }
                .help("New project agent")
            }
        }
        .safeAreaInset(edge: .bottom) {
            EngineStatusBar()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    /// A sidebar agent row showing its name plus a red unread-message badge.
    @ViewBuilder
    private func agentRow(title: String, systemImage: String?, id: UUID) -> some View {
        let isSelected = selectedAgentID == id
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
        if let id = selectedAgentID, let agent = workspace.agent(id: id) {
            ChatView(vm: chatCache.viewModel(for: agent,
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
                "Select an Agent",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Choose an agent from the sidebar to start chatting")
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
        selectedAgentID = created.id
        resetNewAgent()
    }

    private func resetNewAgent() {
        newProjectName = ""
        newAgentName = ""
        showingNewAgent = false
    }

    private func removeAgent(_ agent: AgentRecord) {
        let wasSelected = selectedAgentID == agent.id
        workspace.archiveAgent(id: agent.id)
        chatCache.drop(agent.id)
        if wasSelected { selectedAgentID = workspace.navigator.id }
    }
}

// MARK: - Engine Status Bar

struct EngineStatusBar: View {
    @Environment(MLXInferenceEngine.self) private var engine

    var body: some View {
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
    }

    private var statusColor: Color {
        switch engine.state {
        case .idle: return .gray
        case .loading: return .orange
        case .ready: return .green
        case .generating: return .blue
        case .error: return .red
        }
    }

    private var statusText: String {
        switch engine.state {
        case .idle: return "Ready"
        case .loading(let name): return "Loading \(name)…"
        case .ready(let name): return name
        case .generating: return "Generating…"
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

    func viewModel(for agent: AgentRecord, projectName: String?) -> ChatViewModel {
        if let existing = byID[agent.id] { return existing }
        let vm = ChatViewModel(agent: agent, projectName: projectName)
        byID[agent.id] = vm
        return vm
    }

    /// Drop a cached view-model (e.g. after archiving its agent).
    func drop(_ id: UUID) { byID[id] = nil }
}
