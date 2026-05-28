import SwiftUI

struct ContentView: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @State private var selectedAgentID: UUID?
    @State private var agents: [Agent] = [
        Agent(id: UUID(), name: "General", providerType: .mlx),
        Agent(id: UUID(), name: "Coding", providerType: .mlx),
    ]

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
                ChatView(agent: agent)
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
        case .idle: .gray
        case .loading: .orange
        case .ready: .green
        case .generating: .blue
        case .error: .red
        }
    }

    private var statusText: String {
        switch engine.state {
        case .idle: "No model loaded"
        case .loading(let name): "Loading \(name)…"
        case .ready(let name): name
        case .generating: "Generating…"
        case .error(let msg): msg
        }
    }
}
