import SwiftUI

struct ContentView: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(WorkspaceStore.self) private var workspace
    @State private var selectedAgentID: UUID?
    /// Per-agent chat view-models, kept alive so switching agents preserves the
    /// in-flight view state (history itself is persisted by ChatHistoryStore).
    @State private var chatCache = ChatViewModelCache()
    @State private var showingNewAgent = false
    @State private var newProjectName = ""
    @State private var newAgentName = ""

    var body: some View {
        @Bindable var catalog = catalog

        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Model", selection: $catalog.selectedModelID) {
                    ForEach(catalog.models) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .frame(width: 180)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        #if os(macOS)
        .background(
            WindowSizeConfigurator(
                minSize: CGSize(width: 900, height: 620),
                defaultSize: CGSize(width: 1100, height: 760)
            )
        )
        #endif
        .sheet(isPresented: $showingNewAgent) { newAgentSheet }
        .onAppear {
            if selectedAgentID == nil { selectedAgentID = workspace.navigator.id }
        }
    }

    // MARK: - Sidebar (Navigator + Projects → project agents)

    private var sidebar: some View {
        List(selection: $selectedAgentID) {
            Section("Navigator") {
                Label(workspace.navigator.name,
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(workspace.navigator.id)
            }
            ForEach(workspace.projects) { project in
                Section(project.name) {
                    ForEach(workspace.projectAgents(in: project.id)) { agent in
                        Text(agent.name)
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
    @Environment(OMLXServerManager.self) private var serverManager

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
        .task {
            if case .idle = serverManager.state {
                _ = await serverManager.checkHealth()
            }
        }
    }

    private var statusColor: Color {
        if case .idle = engine.state {
            switch serverManager.state {
            case .idle: return .gray
            case .checking, .launching: return .orange
            case .ready: return .green
            case .failed: return .red
            }
        }

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
        case .idle:
            switch serverManager.state {
            case .idle:
                return "Endpoint not checked"
            case .checking:
                return "Checking oMLX endpoint…"
            case .launching:
                return "Starting oMLX…"
            case .ready:
                if serverManager.configuredModelIsAvailable {
                    return "Endpoint ready · \(shortModelName(serverManager.configuredModelID))"
                }
                if !serverManager.availableModelIDs.isEmpty {
                    return "Endpoint ready · \(serverManager.availableModelIDs.count) models"
                }
                return "Endpoint ready"
            case .failed(let msg):
                return "Endpoint error: \(msg)"
            }
        case .loading(let name): return "Loading \(name)…"
        case .ready(let name): return name
        case .generating: return "Generating…"
        case .error(let msg): return msg
        }
    }

    private func shortModelName(_ id: String) -> String {
        id.count > 32 ? "\(id.prefix(29))…" : id
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
