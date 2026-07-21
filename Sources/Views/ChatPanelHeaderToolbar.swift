import SwiftUI

/// Header toolbar for an agent chat panel: Open in Window, Inbox, Clear Chat.
/// Lives in the panel header (not the window title bar) so it stays visible when
/// the chat is docked in the workspace grid.
struct ChatPanelHeaderToolbar: View {
    let agentID: UUID

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(\.openWindow) private var openWindow
    @State private var showingMessages = false
    @State private var showingClearChatConfirm = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                openWindow(id: "agent-chat-window", value: AgentChatWindowID(agentID: agentID))
            } label: {
                Image(systemName: "macwindow.on.rectangle")
            }
            .help("Open this agent's chat in a floating window")

            Button { showingMessages = true } label: {
                let unread = messageStore.unreadCount(for: agentID)
                Image(systemName: unread > 0 ? "tray.full.fill" : "tray")
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 {
                            Text("\(unread)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Capsule().fill(.red))
                                .offset(x: 8, y: -7)
                        }
                    }
            }
            .help("Inbox")

            Button(role: .destructive) { showingClearChatConfirm = true } label: {
                Image(systemName: "trash")
            }
            .help("Clear this agent's conversation and start fresh")
        }
        .buttonStyle(.plain)
        .font(.caption)
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showingClearChatConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Chat", role: .destructive) { clearChat() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(agentName)'s chat history. Project memory, plans, and tasks are untouched.")
        }
        .sheet(isPresented: $showingMessages) {
            MessagesSheet(agentId: agentID, agentName: agentName)
                .environment(messageStore)
        }
    }

    private var agentName: String {
        workspace.agent(id: agentID)?.name ?? "Agent"
    }

    private func clearChat() {
        guard let agent = workspace.agent(id: agentID),
              let cache = ChatViewModelCache.shared else { return }
        let vm = cache.viewModel(for: agent, projectName: workspace.projectName(for: agent))
        vm.clearChat()
    }
}
