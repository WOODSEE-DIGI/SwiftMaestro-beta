import SwiftUI

// MARK: - Mail view

/// Apple Mail panel: launch Mail, compose messages (in Mail.app via JXA, or in
/// the default client via `mailto:`), and inspect OwnTrack open/click stats
/// for the message currently selected in Mail.
struct MailView: View {
    @Environment(AppleMailService.self) private var service
    @Environment(ThemeStore.self) private var theme

    // Compose form
    @State private var isComposing = false
    @State private var composeTo = ""
    @State private var composeCC = ""
    @State private var composeSubject = ""
    @State private var composeBody = ""

    // Tracking inspector
    @State private var selectedMessage: AppleMailService.SelectedMailMessage?
    @State private var summary: MessageTrackingSummary?
    @State private var events: [TrackingEvent] = []
    @State private var manualMessageID = ""
    @State private var isLoadingTracking = false

    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isComposing {
                composeForm
                    .padding()
            }

            List {
                relaySection
                selectedMessageSection
                if let summary {
                    summarySection(summary)
                }
                if !events.isEmpty {
                    eventsSection
                }
            }
        }
        .task {
            service.requestAuthorization()
            await service.checkRelayHealth()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Mail")
                .font(.headline)
            Spacer()
            Button {
                isComposing.toggle()
            } label: {
                Label("Compose", systemImage: "square.and.pencil")
            }
            Button {
                Task { await refreshTracking() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                service.openMail()
            } label: {
                Label("Open Mail", systemImage: "arrow.up.forward.app")
            }
        }
    }

    // MARK: - Compose form

    private var composeForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message")
                .font(.headline)
            TextField("To (comma separated)", text: $composeTo)
            TextField("Cc (comma separated)", text: $composeCC)
            TextField("Subject", text: $composeSubject)
            TextEditor(text: $composeBody)
                .frame(minHeight: 100)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isComposing = false }
                Button("Default Client") {
                    if service.compose(to: composeTo, cc: composeCC, subject: composeSubject, body: composeBody) {
                        isComposing = false
                    } else {
                        errorMessage = "Could not hand the message to the default email client."
                    }
                }
                .disabled(composeTo.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Draft in Mail") {
                    Task { await composeInMail() }
                }
                .disabled(composeTo.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .background(theme.secondaryBackground)
        .cornerRadius(8)
    }

    // MARK: - Tracking sections

    private var relaySection: some View {
        Section("OwnTrack Relay") {
            HStack(spacing: 8) {
                Circle()
                    .fill(relayStatusColor)
                    .frame(width: 8, height: 8)
                Text(relayStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(service.relayBaseURLString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                if OwnTrackRelayManager.shared.isRunning {
                    Button("Stop Embedded Relay") {
                        OwnTrackRelayManager.shared.stopRelay()
                        Task { await service.checkRelayHealth() }
                    }
                } else {
                    Button("Start Embedded Relay") {
                        OwnTrackRelayManager.shared.startRelay()
                        Task { await service.checkRelayHealth() }
                    }
                }
                if let error = OwnTrackRelayManager.shared.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            HStack {
                TextField("Message-ID (without <>)", text: $manualMessageID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Look Up") {
                    Task { await loadTracking(for: manualMessageID) }
                }
                .disabled(manualMessageID.trimmingCharacters(in: .whitespaces).isEmpty || isLoadingTracking)
            }
        }
    }

    private var selectedMessageSection: some View {
        Section("Selected in Mail") {
            Button {
                Task { await inspectSelectedMessage() }
            } label: {
                Label("Inspect Selected Message", systemImage: "envelope.magnifyingglass")
            }
            .disabled(isLoadingTracking)

            if let selectedMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedMessage.subject ?? "(no subject)")
                        .font(.subheadline.weight(.semibold))
                    if let sender = selectedMessage.sender {
                        Label(sender, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let messageID = selectedMessage.messageID {
                        Label(messageID, systemImage: "number")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func summarySection(_ summary: MessageTrackingSummary) -> some View {
        Section("Tracking Summary") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                statCell("Sent", count: summary.sentCount, icon: "paperplane")
                statCell("Opens", count: summary.openCount, icon: "eye")
                statCell("Clicks", count: summary.clickCount, icon: "hand.tap")
                statCell("Replies", count: summary.replyCount, icon: "arrowshape.turn.up.left")
            }
            .padding(.vertical, 4)

            if !summary.openQualityCounts.isEmpty {
                ForEach(summary.openQualityCounts.sorted(by: { $0.key < $1.key }), id: \.key) { quality, count in
                    HStack {
                        Text(quality)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(count)")
                            .font(.caption.monospacedDigit())
                    }
                }
            }

            if let firstOpened = summary.firstOpenedAt {
                LabeledContent("First opened", value: firstOpened.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }
            if let lastOpened = summary.lastOpenedAt, lastOpened != summary.firstOpenedAt {
                LabeledContent("Last opened", value: lastOpened.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }
            if let firstClicked = summary.firstClickedAt {
                LabeledContent("First clicked", value: firstClicked.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }
        }
    }

    private var eventsSection: some View {
        Section("Events (\(events.count))") {
            ForEach(events.sorted(by: { $0.timestamp > $1.timestamp })) { event in
                HStack(spacing: 8) {
                    Image(systemName: iconForEvent(event.type))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.type.rawValue.capitalized)
                            .font(.caption.weight(.medium))
                        Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let recipient = event.recipient {
                        Text(recipient)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Cells

    private func statCell(_ label: String, count: Int, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(theme.secondaryBackground)
        .cornerRadius(6)
    }

    // MARK: - Helpers

    private var relayStatusColor: Color {
        switch service.relayOnline {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .secondary
        }
    }

    private var relayStatusText: String {
        switch service.relayOnline {
        case .some(true):
            return OwnTrackRelayManager.shared.isRunning ? "Embedded relay running" : "Relay online (external)"
        case .some(false): return "Relay offline — start the embedded relay"
        case .none: return "Checking relay…"
        }
    }

    private func iconForEvent(_ type: TrackingEventType) -> String {
        switch type {
        case .sent: return "paperplane"
        case .open: return "eye"
        case .click: return "hand.tap"
        case .reply: return "arrowshape.turn.up.left"
        }
    }

    private func splitAddresses(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Actions

    private func composeInMail() async {
        errorMessage = nil
        do {
            _ = try await service.composeInMailApp(
                to: splitAddresses(composeTo),
                cc: splitAddresses(composeCC),
                subject: composeSubject,
                content: composeBody
            )
            isComposing = false
        } catch {
            errorMessage = "Mail compose failed: \(error.localizedDescription)"
        }
    }

    private func refreshTracking() async {
        errorMessage = nil
        // Auto-start the embedded relay when nothing is listening yet.
        await service.ensureRelayRunning()
        if summary != nil, let id = selectedMessage?.messageID ?? Optional(manualMessageID) {
            await loadTracking(for: id)
        }
    }

    private func inspectSelectedMessage() async {
        errorMessage = nil
        isLoadingTracking = true
        defer { isLoadingTracking = false }
        do {
            let message = try await service.selectedMessage()
            selectedMessage = message
            guard let message, let messageID = message.messageID, !messageID.isEmpty else {
                if selectedMessage == nil {
                    errorMessage = "No message selected in Mail (or Mail has no viewer open)."
                }
                return
            }
            manualMessageID = AppleMailService.normalizeMessageID(messageID)
            await loadTracking(for: messageID)
        } catch {
            errorMessage = "Could not read Mail's selection: \(error.localizedDescription)"
        }
    }

    private func loadTracking(for messageID: String) async {
        errorMessage = nil
        isLoadingTracking = true
        defer { isLoadingTracking = false }
        let normalized = AppleMailService.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return }
        guard await service.ensureRelayRunning() else {
            errorMessage = "No relay reachable at \(service.relayBaseURLString) and the embedded relay failed to start."
            return
        }
        do {
            async let fetchedSummary = service.trackingSummary(messageID: normalized)
            async let fetchedEvents = service.trackingEvents(messageID: normalized)
            summary = try await fetchedSummary
            events = try await fetchedEvents
        } catch {
            summary = nil
            events = []
            errorMessage = "No tracking data for \(normalized): \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#Preview {
    MailView()
        .environment(AppleMailService.shared)
        .environment(ThemeStore())
}
