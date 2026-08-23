import SwiftUI

// MARK: - Self-Healing Settings Tab
//
// Visibility into the ToolCallGuardian: what failed, what healed itself, and
// which per-model quirks have been learned (and now prevent failures before
// they happen). The guardian is an actor, so stats load asynchronously into
// local state on appear / on Refresh.

struct SelfHealingSettingsTab: View {
    @Environment(ThemeStore.self) private var theme

    @State private var notifyOnUnhealed = true
    @State private var statsText = "Loading…"
    @State private var failuresText = ""
    @State private var logPath = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                Text("Tool Self-Healing")
                    .font(.title2)
                    .foregroundStyle(theme.chatText)

                Text("When a tool call fails — a popup blocker stops a browser "
                     + "action, a database is busy, a model emits the wrong argument "
                     + "type — SwiftMaestro classifies the failure, retries transient "
                     + "faults automatically, and hands the agent a recovery hint so "
                     + "it can route around the problem. Fixes that heal the same "
                     + "failure twice are learned per model and applied before the "
                     + "call next time — new models (LM Studio, Ollama, online) teach "
                     + "themselves instead of needing manual fixes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Notify me when a failure can't be self-healed",
                       isOn: $notifyOnUnhealed)
                    .foregroundStyle(theme.chatText)
                    .onChange(of: notifyOnUnhealed) { _, newValue in
                        Task { await ToolCallGuardian.shared.setNotificationsEnabled(newValue) }
                    }

                Divider()

                HStack {
                    Text("Activity")
                        .font(.headline)
                        .foregroundStyle(theme.chatText)
                    Spacer()
                    Button("Refresh") { loadStats() }
                        .controlSize(.small)
                }

                Text(statsText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !failuresText.isEmpty {
                    Text("Recent Failures")
                        .font(.headline)
                        .foregroundStyle(theme.chatText)
                    Text(failuresText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !logPath.isEmpty {
                    Text("Full log: \(logPath)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
        }
        .task { loadStats() }
    }

    private func loadStats() {
        Task {
            let guardian = ToolCallGuardian.shared
            notifyOnUnhealed = await guardian.notificationsEnabled
            statsText = await guardian.statsSummary()
            failuresText = await guardian.recentFailuresText(limit: 25)
            logPath = guardian.failureLogPath
        }
    }
}
