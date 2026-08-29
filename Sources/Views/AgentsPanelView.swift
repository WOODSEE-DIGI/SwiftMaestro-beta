import SwiftUI

/// The agent navigator list (Maestro + built-in agents + project agents,
/// grouped by category), rendered as a normal tiling panel so it can
/// dock/float/move like every other panel instead of living in a fixed left
/// sidebar. Tapping an agent opens or focuses its chat panel via the shared
/// `openWorkspacePanel` notification. Hovering shows a tooltip describing
/// what the agent does in plain language.
struct AgentsPanelView: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(ThemeStore.self) private var theme
    @State private var layout = WorkspaceLayoutState.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .newAgentRequested, object: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New project agent")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            GeometryReader { proxy in
                List {
                    Section {
                        agentRow(
                            workspace.navigator,
                            systemImage: "point.3.connected.trianglepath.dotted",
                            tooltip: "Your main assistant. Answers questions, writes text, and delegates to specialist agents when needed."
                        )
                        agentRow(
                            workspace.swiftHelper,
                            systemImage: "wrench.and.screwdriver",
                            tooltip: "SwiftMaestro's own support agent. Diagnoses crashes, fixes settings, manages MCP servers, and repairs the app when something breaks."
                        )
                        agentRow(
                            workspace.coder,
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            tooltip: "Reads, edits, and writes code. Builds and tests projects. Works inside your codebase like an in-process coding assistant."
                        )
                        agentRow(
                            workspace.searcher,
                            systemImage: "magnifyingglass",
                            tooltip: "Finds information fast — from the web, Google Maps, local files, network drives, or your Obsidian vault."
                        )
                    } header: {
                        Text("Agents")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.sidebarText.opacity(0.7))
                    }
                    ForEach(workspace.projectAgentsByCategory(), id: \.category) { group in
                        Section {
                            ForEach(group.agents) { agent in
                                agentRow(
                                    agent,
                                    subtitle: workspace.projectName(for: agent),
                                    systemImage: workspace.resolvedCategory(for: agent).systemImage,
                                    tooltip: workspace.resolvedCategory(for: agent).displayName
                                )
                            }
                        } header: {
                            HStack(spacing: 4) {
                                Image(systemName: group.category.systemImage)
                                    .font(.system(size: 10))
                                Text(group.category.displayName)
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.sidebarText.opacity(0.7))
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(theme.sidebarBackground)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }

            VStack(alignment: .leading, spacing: 8) {
                EngineStatusBar()
                ProcessResourceMonitor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func agentRow(
        _ agent: AgentRecord,
        subtitle: String? = nil,
        systemImage: String? = nil,
        tooltip: String? = nil
    ) -> some View {
        let isOpen = layout.isOpen(.agentChat(agent.id))
        let unread = (messageStore.inboxes[agent.id] ?? []).filter { !$0.read }.count
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                if let systemImage {
                    Label(agent.name, systemImage: systemImage)
                        .font(.system(size: 13))
                } else {
                    Text(agent.name)
                        .font(.system(size: 13))
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.sidebarText.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(theme.sidebarText)
            Spacer()
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
        .contentShape(Rectangle())
        .help(tooltip ?? agent.name)
        .onTapGesture {
            NotificationCenter.default.post(
                name: .openWorkspacePanel, object: WorkspacePanelKind.agentChat(agent.id))
        }
        .contextMenu {
            Button("Clear Chat") {
                ChatViewModelCache.shared.viewModel(
                    for: agent, projectName: workspace.projectName(for: agent)
                ).clearChat()
            }
            Button("Change Category") {
                NotificationCenter.default.post(name: .agentCategoryRequested, object: agent)
            }
            Button("Remove Agent", role: .destructive) {
                NotificationCenter.default.post(name: .removeAgentRequested, object: agent)
            }
        }
    }
}
