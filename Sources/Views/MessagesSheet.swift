import SwiftUI

/// An agent's inbox of inter-agent messages. Opening marks them read.
struct MessagesSheet: View {
    @Environment(AgentMessageStore.self) private var messageStore
    @Environment(\.dismiss) private var dismiss
    let agentId: UUID
    let agentName: String

    var body: some View {
        let messages = messageStore.inboxes[agentId] ?? []
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                Text("\(agentName) — Inbox").font(.headline)
                Spacer()
                if !messages.isEmpty {
                    Button("Clear") { messageStore.clear(for: agentId) }
                        .font(.caption)
                }
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()

            if messages.isEmpty {
                Spacer()
                Text("No messages. Other agents can send some with send_agent_message.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(messages.reversed()) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(message.subject).font(.body.weight(.semibold))
                                    Spacer()
                                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Text("from \(message.fromName)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(message.body)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.secondary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 560, height: 520)
        .task {
            _ = messageStore.inbox(for: agentId)
            // Reading the inbox marks everything read.
            messageStore.markAllRead(for: agentId)
        }
    }
}
