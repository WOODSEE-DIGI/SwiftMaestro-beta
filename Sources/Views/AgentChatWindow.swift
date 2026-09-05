import SwiftUI

/// Lightweight identifier for a detached agent chat `WindowGroup`. Passing only
/// the agent ID keeps the window value small and lets the view read the live
/// agent record plus its cached `ChatViewModel`.
struct AgentChatWindowID: Hashable, Codable {
    let agentID: UUID
}

/// A floating, resizable chat window for a single agent. Opened manually from
/// the main chat toolbar, or automatically when Maestro delegates to a
/// sub-agent so the user can watch both agents at once.
struct AgentChatWindowView: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @Environment(VisionProxyService.self) private var visionProxyService
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(TodoStore.self) private var todoStore
    @Environment(PlanStore.self) private var planStore
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(ThemeStore.self) private var theme
    @Environment(WhisperKitService.self) private var whisper

    /// The target agent, or `nil` when SwiftUI opens the group without a value.
    let target: AgentChatWindowID?

    /// Cached view-model for this window. Held in state so it survives view
    /// updates; the shared cache keeps the same instance in sync with the main
    /// window and with delegation streaming.
    @State private var vm: ChatViewModel?
    /// Per-window Plans/Tasks layout state shared with the embedded ChatView.
    @State private var panelLayout = PanelLayoutState()
    /// Keep this window in front of all others. Opt-in, off by default.
    @State private var isPinnedToFront = false

    private var agent: AgentRecord? {
        target.flatMap { workspace.agent(id: $0.agentID) }
    }

    var body: some View {
        Group {
            if let vm {
                ChatView(vm: vm, title: vm.agent.name)
                    .environment(panelLayout)
            } else if agent == nil {
                missingAgentView
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading chat…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(
            WindowSizeConfigurator(
                minSize: CGSize(width: 720, height: 520),
                defaultSize: CGSize(width: 960, height: 720),
                backgroundColor: nil
            )
        )
        #if os(macOS)
        .background(WindowPinConfigurator(isPinned: isPinnedToFront))
        .background(
            WindowFocusObserver(
                name: .bringAgentChatToFront,
                match: { [agentID = target?.agentID] object in
                    guard let objectID = object as? UUID else { return false }
                    return objectID == agentID
                }
            )
        )
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPinnedToFront.toggle()
                } label: {
                    Label(
                        isPinnedToFront ? "Unpin" : "Keep on Top",
                        systemImage: isPinnedToFront ? "pin.fill" : "pin"
                    )
                }
                .help(isPinnedToFront
                    ? "Stop keeping this window in front of all others"
                    : "Keep this window in front of all others")
            }
        }
        .onAppear { bindViewModel() }
        .onChange(of: target) { _, _ in bindViewModel() }
    }

    private func bindViewModel() {
        guard let agent else {
            vm = nil
            return
        }
        vm = ChatViewModelCache.shared.viewModel(
            for: agent,
            projectName: workspace.projectName(for: agent)
        )
    }

    private var missingAgentView: some View {
        ContentUnavailableView(
            "Agent not found",
            systemImage: "bubble.left.and.exclamationmark.bubble.right",
            description: Text("The agent for this window no longer exists.")
        )
        .frame(minWidth: 400, minHeight: 300)
    }
}
