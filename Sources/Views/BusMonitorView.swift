import SwiftUI

/// Live view of the SwiftMaestro internal agent bus.
///
/// Shows topics, messages, and subscribers. It polls the `AgentBus` actor
/// periodically because the bus itself is an actor and doesn't broadcast
/// change events yet.
@MainActor
@Observable
final class BusMonitorViewModel {
    var topics: [BusTopicSnapshot] = []
    var selectedTopic: String?
    var messages: [AgentBusMessage] = []
    var subscribers: [String] = []
    var errorMessage: String?
    var isLoading = false
    var autoRefresh = true
    var lastRefresh: Date?

    // nonisolated(unsafe): deinit is nonisolated and must be able to cancel
    // the task. The task is only ever written from MainActor contexts.
    nonisolated(unsafe) private var refreshTask: Task<Void, Never>?
    private let refreshInterval: Duration = .seconds(2)

    deinit {
        refreshTask?.cancel()
    }

    func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.refreshInterval ?? .seconds(2))
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        self.isLoading = true
        let allTopics = await AgentBus.shared.topics()
        var snapshots: [BusTopicSnapshot] = []
        for topic in allTopics {
            let count = await AgentBus.shared.read(topic: topic, agentID: BusMonitorViewModel.agentID).count
            snapshots.append(BusTopicSnapshot(topic: topic, messageCount: count))
        }
        let selected = self.selectedTopic ?? snapshots.first?.topic
        let msgs: [AgentBusMessage]
        let subs: [String]
        if let selected {
            msgs = await AgentBus.shared.read(
                topic: selected,
                agentID: BusMonitorViewModel.agentID,
                limit: 100)
            subs = await AgentBus.shared.subscriptions(for: BusMonitorViewModel.agentID)
                .filter { $0 == selected }
                .sorted()
        } else {
            msgs = []
            subs = []
        }

        self.topics = snapshots
        if self.selectedTopic == nil || !snapshots.contains(where: { $0.topic == self.selectedTopic }) {
            self.selectedTopic = selected
        }
        self.messages = msgs
        self.subscribers = subs
        self.lastRefresh = Date()
        self.errorMessage = nil
        self.isLoading = false
    }

    func selectTopic(_ topic: String?) {
        selectedTopic = topic
        Task { await refresh() }
    }

    /// Stable synthetic agent ID for the monitor's own reads. It doesn't need
    /// to correspond to a real agent; it just identifies the monitor's read cursor.
    private static let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

struct BusTopicSnapshot: Identifiable, Hashable {
    let topic: String
    let messageCount: Int
    var id: String { topic }
}

struct BusMonitorView: View {
    @State private var viewModel = BusMonitorViewModel()
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        HStack(spacing: 0) {
            topicList
            Divider()
            messagePane
        }
        .onAppear {
            viewModel.startRefreshing()
            Task { await viewModel.refresh() }
        }
        .onDisappear {
            viewModel.stopRefreshing()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Toggle("Auto-refresh", isOn: $viewModel.autoRefresh)
                    .toggleStyle(.switch)
                    .onChange(of: viewModel.autoRefresh) { _, isOn in
                        if isOn {
                            viewModel.startRefreshing()
                        } else {
                            viewModel.stopRefreshing()
                        }
                    }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
    }

    private var topicList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Topics")
                    .font(.headline)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if viewModel.topics.isEmpty {
                ContentUnavailableView(
                    "No Topics",
                    systemImage: "network",
                    description: Text("Bus messages will appear here as agents publish them.")
                )
            } else {
                List(viewModel.topics, selection: $viewModel.selectedTopic) { topic in
                    HStack {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(theme.accent)
                        Text(topic.topic)
                        Spacer()
                        Text("\(topic.messageCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(topic.topic)
                }
                .listStyle(.plain)
            }

            if let last = viewModel.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .frame(minWidth: 220, idealWidth: 260)
    }

    private var messagePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(viewModel.selectedTopic ?? "Messages")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(viewModel.subscribers.count) subscriber(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if viewModel.selectedTopic == nil || viewModel.messages.isEmpty {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "bubble.left.and.exclamationmark",
                    description: Text("Select a topic to see its bus history.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.messages) { message in
                            BusMessageRow(message: message)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 320)
    }
}

struct BusMessageRow: View {
    let message: AgentBusMessage
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconForKind(message.kind))
                    .foregroundStyle(theme.accent)
                Text(message.senderName)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let replyID = message.inReplyTo {
                    Text("→ \(replyID.uuidString.prefix(8))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(message.payload)
                .font(.body)
                .textSelection(.enabled)
            HStack {
                Text("ID: \(message.id.uuidString.prefix(8))")
                Spacer()
                Text(message.kind.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accent.opacity(0.15)))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(theme.background.opacity(0.5))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.accent.opacity(0.2), lineWidth: 1)
        )
    }

    private func iconForKind(_ kind: AgentBusMessageKind) -> String {
        switch kind {
        case .event: return "bubble.left"
        case .request: return "arrow.up.message"
        case .reply: return "arrow.down.message"
        case .task: return "checklist"
        case .status: return "pulse"
        }
    }
}

#Preview {
    BusMonitorView()
}
