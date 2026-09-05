import SwiftUI

// MARK: - Swift Helper Settings Tab
//
// Swift Helper is the umbrella for runtime repair: ToolCallGuardian's
// self-healing, configuration restore points, and — when a problem needs a
// code fix — the user-facing ticketing flow that sends an anonymous diagnostic
// report. The guardian is an actor, so stats load asynchronously into local
// state on appear / on Refresh.

struct SwiftHelperSettingsTab: View {
    @Environment(ThemeStore.self) private var theme

    @State private var notifyOnUnhealed = true
    @State private var statsText = "Loading…"
    @State private var failuresText = ""
    @State private var logPath = ""
    @State private var tickets: [SentTicket] = []
    @State private var recentCrashes: [CrashTicketItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                Text("Swift Helper")
                    .font(.title2)
                    .foregroundStyle(theme.chatText)

                Text("Swift Helper watches for problems it can repair at runtime: "
                     + "blocked browser popups, busy databases, bad model arguments, "
                     + "and misbehaving settings. When it can't fix something itself, "
                     + "it can open an anonymous diagnostic report so the developers "
                     + "get the evidence they need to ship a code fix.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // MARK: Ticketing
                ticketingSection

                Divider()

                // MARK: Self-Healing
                Text("Tool Self-Healing")
                    .font(.headline)
                    .foregroundStyle(theme.chatText)

                Text("When a tool call fails, SwiftMaestro classifies the failure, "
                     + "retries transient faults automatically, and hands the agent a "
                     + "recovery hint. Fixes that heal the same failure twice are learned "
                     + "per model and applied before the call next time.")
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
                    Button("Refresh") { load() }
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
        .task { load() }
    }

    // MARK: - Ticketing UI

    private var ticketingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Problem Reports")
                    .font(.headline)
                    .foregroundStyle(theme.chatText)
                Spacer()
                Button {
                    NotificationCenter.default.post(
                        name: .openDiagnosticReport,
                        object: nil,
                        userInfo: ["description": ""]
                    )
                } label: {
                    Label("New Report", systemImage: "exclamationmark.bubble")
                }
                .controlSize(.small)
            }

            Text("Send an anonymous diagnostic report when Swift Helper can't repair "
                 + "something. You review the exact redacted payload before it leaves "
                 + "your Mac; attachments are scanned on this machine before they are included.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !recentCrashes.isEmpty {
                Text("Recent crashes")
                    .font(.subheadline)
                    .foregroundStyle(theme.chatText)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(recentCrashes.prefix(3)) { crash in
                        HStack {
                            Text(crash.headline)
                                .font(.caption)
                                .foregroundStyle(theme.chatText)
                            Spacer()
                            Button("Report…") {
                                NotificationCenter.default.post(
                                    name: .openDiagnosticReport,
                                    object: nil,
                                    userInfo: [
                                        "description": "SwiftMaestro crashed: \(crash.headline)"
                                    ]
                                )
                            }
                            .controlSize(.mini)
                        }
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if tickets.isEmpty {
                Text("No reports sent yet.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Sent reports")
                    .font(.subheadline)
                    .foregroundStyle(theme.chatText)
                ForEach(tickets.prefix(10)) { ticket in
                    HStack(spacing: 8) {
                        Image(systemName: ticket.hadAttachment ? "paperclip" : "checkmark.circle.fill")
                            .foregroundStyle(ticket.hadAttachment ? Color.secondary : Color.green)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ticket.title)
                                .font(.caption)
                                .foregroundStyle(theme.chatText)
                                .lineLimit(1)
                            Text("\(ticket.date.formatted(date: .abbreviated, time: .shortened)) · ref \(ticket.referenceID)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            SentTicketStore.shared.delete(ticket)
                            loadTickets()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func load() {
        Task {
            let guardian = ToolCallGuardian.shared
            notifyOnUnhealed = await guardian.notificationsEnabled
            statsText = await guardian.statsSummary()
            failuresText = await guardian.recentFailuresText(limit: 25)
            logPath = guardian.failureLogPath
            loadTickets()
            loadRecentCrashes()
        }
    }

    private func loadTickets() {
        tickets = SentTicketStore.shared.allTickets
    }

    private func loadRecentCrashes() {
        let dir = URL(fileURLWithPath: SystemHealthWatchService.reportsDir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        recentCrashes = files
            .filter { $0.lastPathComponent.hasPrefix("SwiftMaestro") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date, CrashSummary)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      date > cutoff,
                      let summary = SystemHealthWatchService.parseReport(at: url) else { return nil }
                return (url, date, summary)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { _, _, summary in
                CrashTicketItem(
                    id: summary.path,
                    headline: summary.headline
                )
            }
    }
}

// MARK: - Crash ticket helper

private struct CrashTicketItem: Identifiable {
    let id: String
    let headline: String
}
