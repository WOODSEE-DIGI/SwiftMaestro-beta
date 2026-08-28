import SwiftUI

/// Header toolbar for an agent chat panel: Plans, Todo, Open in Window,
/// Inbox, Clear Chat. Lives in the panel header (not the window title bar)
/// so it stays visible when the chat is docked in the workspace grid.
struct ChatPanelHeaderToolbar: View {
    let agentID: UUID

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(\.openWindow) private var openWindow
    @State private var layout = WorkspaceLayoutState.shared
    @State private var panelLayout = PanelLayoutState.shared
    @State private var showingMessages = false
    @State private var showingClearChatConfirm = false

    var body: some View {
        HStack(spacing: 6) {
            // Plans toggle — show/hide the Plans side panel
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    panelLayout.toggleVisibility(.plans)
                }
            } label: {
                Image(systemName: panelLayout.hiddenPanels.contains(.plans)
                    ? "list.bullet.rectangle" : "list.bullet.rectangle.fill")
            }
            .help(panelLayout.hiddenPanels.contains(.plans)
                ? "Show Plans panel" : "Hide Plans panel")

            // Tasks/Todo toggle — show/hide the Tasks side panel
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    panelLayout.toggleVisibility(.tasks)
                }
            } label: {
                Image(systemName: panelLayout.hiddenPanels.contains(.tasks)
                    ? "checklist" : "checklist.checked")
            }
            .help(panelLayout.hiddenPanels.contains(.tasks)
                ? "Show Tasks panel" : "Hide Tasks panel")

            Button {
                floatOrFocus()
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

    /// Open this agent's chat in a tracked floating workspace panel, or bring
    /// the existing floating panel to the front. This keeps the sidebar's
    /// "open" indicator and the focus notification in sync, instead of opening
    /// an untracked `AgentChatWindow` that the sidebar can't find later.
    private func floatOrFocus() {
        let kind = WorkspacePanelKind.agentChat(agentID)
        if layout.isFloating(kind) {
            NotificationCenter.default.post(name: .bringWorkspacePanelToFront, object: kind)
            return
        }
        if layout.isOpen(kind) {
            layout.float(kind)
        } else {
            let result = layout.open(kind)
            if result == .dockedDirectly {
                layout.float(kind)
            }
        }
        openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
    }

    private func clearChat() {
        // Clear by ID unconditionally: previously this guarded on the agent
        // record existing, so a panel whose agent lookup failed (stale layout
        // tile, unpersisted agent, or an agent restored differently after
        // relaunch) silently did NOTHING — the dialog dismissed and the chat
        // stayed. Clear by ID instead: drop the cached view-model (the panel
        // re-creates a fresh one on next render) and remove any persisted
        // history file for the same id.
        ChatHistoryStore.clear(agentId: agentID)
        if let agent = workspace.agent(id: agentID) {
            let vm = ChatViewModelCache.shared.viewModel(
                for: agent, projectName: workspace.projectName(for: agent))
            NSLog("[CLEARCHAT] clearing \(agent.name) (\(agentID)) — \(vm.messages.count) messages before clear")
            vm.clearChat()
        } else {
            NSLog("[CLEARCHAT] agent \(agentID) not found in workspace — cleared history file and dropped cached VM only")
            ChatViewModelCache.shared.drop(agentID)
        }
    }
}
