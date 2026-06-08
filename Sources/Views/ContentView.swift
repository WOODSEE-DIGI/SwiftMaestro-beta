import SwiftUI

struct ContentView: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @State private var selectedAgentID: UUID?
    @State private var agents: [Agent] = Agent.defaultAgentNames.map {
        Agent(name: $0, providerType: .mlx)
    }
    /// Per-agent chat view-models, kept alive so switching agents preserves history.
    @State private var chatCache = ChatViewModelCache()

    var body: some View {
        @Bindable var catalog = catalog

        NavigationSplitView {
            List(agents, selection: $selectedAgentID) { agent in
                Text(agent.name)
            }
            .navigationTitle("SwiftMaestro")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        agents.append(Agent(id: UUID(), name: "New Agent", providerType: .mlx))
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                EngineStatusBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        } detail: {
            if let agentID = selectedAgentID,
               let agent = agents.first(where: { $0.id == agentID }) {
                ChatView(vm: chatCache.viewModel(for: agent))
            } else {
                ContentUnavailableView(
                    "Select an Agent",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Choose an agent from the sidebar to start chatting")
                )
            }
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

    func viewModel(for agent: Agent) -> ChatViewModel {
        if let existing = byID[agent.id] { return existing }
        let vm = ChatViewModel(agent: agent)
        byID[agent.id] = vm
        return vm
    }
}
