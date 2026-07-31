import SwiftUI
import AppKit

// MARK: - Mail view

/// Webmail-style Mail panel: mailbox sidebar, message list, and reading pane
/// rendered on top of Mail.app's live data (via `AppleMailReader`), with the
/// OwnTrack tracking inspector as a second mode. Compose hands drafts to
/// Mail.app (JXA) or the default client (mailto:).
struct MailView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case mailbox, tracking
        var id: String { rawValue }
        var title: String { self == .mailbox ? "Mailbox" : "Tracking" }
        var icon: String { self == .mailbox ? "tray" : "chart.line.uptrend.xyaxis" }
    }

    @Environment(AppleMailService.self) private var service
    @Environment(ThemeStore.self) private var theme
    @State private var reader = AppleMailReader.shared

    @State private var mode: Mode = .mailbox

    // Mailbox state
    @State private var selectedMailbox: AppleMailReader.MailboxRef? = .unified(.inbox)
    @State private var messages: [AppleMailReader.MessageSummary] = []
    @State private var selectedMessageID: Int?
    @State private var detail: AppleMailReader.MessageDetail?
    @State private var searchText = ""
    @State private var listLimit = 50
    @State private var isLoadingList = false
    @State private var isLoadingDetail = false
    @State private var mailboxError: String?

    // Compose sheet
    @State private var isComposing = false
    @State private var composeTo = ""
    @State private var composeCC = ""
    @State private var composeSubject = ""
    @State private var composeBody = ""

    // Tracking state
    @State private var selectedTrackedMessage: AppleMailService.SelectedMailMessage?
    @State private var summary: MessageTrackingSummary?
    @State private var events: [TrackingEvent] = []
    @State private var manualMessageID = ""
    @State private var isLoadingTracking = false
    @State private var trackingError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            switch mode {
            case .mailbox: mailboxMode
            case .tracking: trackingMode
            }
        }
        .task {
            service.requestAuthorization()
            await service.ensureRelayRunning()
            await refreshMailbox()
        }
        .sheet(isPresented: $isComposing) { composeSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Mail")
                .font(.headline)
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Label(m.title, systemImage: m.icon).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            Spacer()
            Button { isComposing = true } label: {
                Label("Compose", systemImage: "square.and.pencil")
            }
            if mode == .mailbox {
                Button { Task { await getMail() } } label: {
                    Label("Get Mail", systemImage: "arrow.down.circle")
                }
            }
            Button { Task { await refreshAll() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button { service.openMail() } label: {
                Label("Open Mail", systemImage: "arrow.up.forward.app")
            }
        }
    }

    // MARK: - Mailbox mode

    private var mailboxMode: some View {
        HSplitView {
            mailboxSidebar
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
            messageList
                .frame(minWidth: 260, idealWidth: 340)
            readingPane
                .frame(minWidth: 380)
                .layoutPriority(1)
        }
    }

    // MARK: Mailbox sidebar

    private var mailboxSidebar: some View {
        List(selection: $selectedMailbox) {
            Section("Favourites") {
                ForEach(AppleMailReader.UnifiedKind.allCases, id: \.self) { kind in
                    mailboxRow(
                        title: kind.title,
                        icon: kind.icon,
                        unread: reader.unified?.unread(for: kind)
                    )
                    .tag(AppleMailReader.MailboxRef.unified(kind))
                }
            }
            if !reader.accounts.isEmpty {
                Section("Accounts") {
                    ForEach(reader.accounts) { account in
                        Section(account.name) {
                            ForEach(account.mailboxes, id: \.name) { mailbox in
                                mailboxRow(
                                    title: mailbox.name,
                                    icon: "folder",
                                    unread: mailbox.unread
                                )
                                .tag(AppleMailReader.MailboxRef.account(
                                    accountName: account.name, mailboxName: mailbox.name))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selectedMailbox) { _, _ in
            selectedMessageID = nil
            detail = nil
            Task { await loadMessages() }
        }
        .overlay {
            if reader.isLoadingStructure {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func mailboxRow(title: String, icon: String, unread: Int?) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if let unread, unread > 0 {
                Text("\(unread)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: Message list

    private var filteredMessages: [AppleMailReader.MessageSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return messages }
        return messages.filter {
            $0.subject.lowercased().contains(query) || $0.sender.lowercased().contains(query)
        }
    }

    private var messageList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search \(selectedMailbox?.displayName ?? "mailbox")", text: $searchText)
                    .textFieldStyle(.plain)
                if isLoadingList { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(theme.secondaryBackground.opacity(0.5))

            Divider()

            if let mailboxError {
                Text(mailboxError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            List(selection: $selectedMessageID) {
                ForEach(filteredMessages) { message in
                    messageRow(message)
                        .tag(message.id)
                        .contextMenu { messageContextMenu(message) }
                }
                if messages.count >= listLimit {
                    Button("Load older messages…") {
                        listLimit += 50
                        Task { await loadMessages() }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            .listStyle(.plain)
            .onChange(of: selectedMessageID) { _, _ in
                Task { await loadDetail() }
            }
        }
    }

    private func messageRow(_ message: AppleMailReader.MessageSummary) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(message.isRead ? Color.clear : theme.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(displayName(from: message.sender))
                        .font(.callout.weight(message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(message.date.map(Self.dateLabel) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Reading pane

    private var readingPane: some View {
        VStack(spacing: 0) {
            if let detail {
                actionBar
                Divider()
                messageHeaders(detail)
                Divider()
                messageBody(detail)
            } else {
                Spacer()
                ContentUnavailableView(
                    "No Message Selected",
                    systemImage: "envelope.open",
                    description: Text("Pick a message from the list, or Get Mail to fetch new ones.")
                )
                Spacer()
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { performMessageAction { try await reader.reply(in: $0, id: $1, toAll: false) } } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }.help("Reply")
            Button { performMessageAction { try await reader.reply(in: $0, id: $1, toAll: true) } } label: {
                Image(systemName: "arrowshape.turn.up.left.2")
            }.help("Reply All")
            Button { performMessageAction { try await reader.forward(in: $0, id: $1) } } label: {
                Image(systemName: "arrowshape.turn.up.right")
            }.help("Forward")
            Divider().frame(height: 16)
            Button { performMessageAction(refreshes: false) { ref, id in
                try await reader.setFlagged(!(detail?.isFlagged ?? false), in: ref, id: id)
            } } label: {
                Image(systemName: detail?.isFlagged == true ? "flag.fill" : "flag")
            }.help(detail?.isFlagged == true ? "Unflag" : "Flag")
            Button { performMessageAction { ref, id in
                try await reader.archive(in: ref, id: id)
            } } label: {
                Image(systemName: "archivebox")
            }.help("Archive")
            Button { performMessageAction { ref, id in
                try await reader.delete(in: ref, id: id)
            } } label: {
                Image(systemName: "trash")
            }.help("Move to Trash")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func messageHeaders(_ detail: AppleMailReader.MessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(detail.subject)
                .font(.headline)
            HStack(spacing: 4) {
                Text("From:").foregroundStyle(.secondary)
                Text(detail.sender)
            }
            .font(.callout)
            if !detail.to.isEmpty {
                HStack(spacing: 4) {
                    Text("To:").foregroundStyle(.secondary)
                    Text(detail.to.joined(separator: ", "))
                }
                .font(.caption)
            }
            HStack(spacing: 4) {
                if let date = detail.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                Spacer()
                if !detail.messageID.isEmpty {
                    Text(detail.messageID)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messageBody(_ detail: AppleMailReader.MessageDetail) -> some View {
        ScrollView {
            Group {
                if isLoadingDetail {
                    ProgressView().padding()
                } else {
                    Text(renderedBody(for: detail))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
    }

    // MARK: Body rendering (HTML → AttributedString, cached)

    @State private var renderedBodies: [Int: AttributedString] = [:]

    private func renderedBody(for detail: AppleMailReader.MessageDetail) -> AttributedString {
        let key = detail.messageID.hashValue
        if let cached = renderedBodies[key] { return cached }
        let content = detail.content
        let looksHTML = content.range(of: "<html", options: .caseInsensitive) != nil
            || content.range(of: "<body", options: .caseInsensitive) != nil
            || content.range(of: "</div>", options: .caseInsensitive) != nil
        let rendered: AttributedString
        if looksHTML, let data = content.data(using: .utf8),
           let nsAttr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil) {
            // Strip explicit foreground colors from the HTML so body text
            // follows the app theme — sender-supplied black text would be
            // invisible on our dark background. Links keep their underline
            // and remain tappable; only the color is dropped.
            let mutable = NSMutableAttributedString(attributedString: nsAttr)
            mutable.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: mutable.length))
            rendered = (try? AttributedString(mutable as NSAttributedString, including: \.appKit)) ?? AttributedString(mutable.string)
        } else {
            rendered = AttributedString(content)
        }
        renderedBodies[key] = rendered
        return rendered
    }

    // MARK: Tracking mode

    private var trackingMode: some View {
        List {
            relaySection
            selectedMessageSection
            if let summary { summarySection(summary) }
            if !events.isEmpty { eventsSection }
        }
    }

    private var relaySection: some View {
        Section("OwnTrack Relay") {
            HStack(spacing: 8) {
                Circle().fill(relayStatusColor).frame(width: 8, height: 8)
                Text(relayStatusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(service.relayBaseURLString)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
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
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }
            HStack {
                TextField("Message-ID (without <>)", text: $manualMessageID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Look Up") { Task { await loadTracking(for: manualMessageID) } }
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

            if let selectedTrackedMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedTrackedMessage.subject ?? "(no subject)")
                        .font(.subheadline.weight(.semibold))
                    if let sender = selectedTrackedMessage.sender {
                        Label(sender, systemImage: "person")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let messageID = selectedTrackedMessage.messageID {
                        Label(messageID, systemImage: "number")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
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
                        Text(quality).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(count)").font(.caption.monospacedDigit())
                    }
                }
            }
            if let firstOpened = summary.firstOpenedAt {
                LabeledContent("First opened", value: firstOpened.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
            if let lastOpened = summary.lastOpenedAt, lastOpened != summary.firstOpenedAt {
                LabeledContent("Last opened", value: lastOpened.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
            if let firstClicked = summary.firstClickedAt {
                LabeledContent("First clicked", value: firstClicked.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
        }
    }

    private var eventsSection: some View {
        Section("Events (\(events.count))") {
            ForEach(events.sorted(by: { $0.timestamp > $1.timestamp })) { event in
                HStack(spacing: 8) {
                    Image(systemName: iconForEvent(event.type))
                        .foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.type.rawValue.capitalized).font(.caption.weight(.medium))
                        Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let recipient = event.recipient {
                        Text(recipient).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Compose sheet

    private var composeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message").font(.headline)
            TextField("To (comma separated)", text: $composeTo)
            TextField("Cc (comma separated)", text: $composeCC)
            TextField("Subject", text: $composeSubject)
            TextEditor(text: $composeBody)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isComposing = false }
                Button("Default Client") {
                    if service.compose(to: composeTo, cc: composeCC, subject: composeSubject, body: composeBody) {
                        isComposing = false
                    }
                }
                .disabled(composeTo.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Draft in Mail") { Task { await composeInMail() } }
                    .disabled(composeTo.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .frame(width: 480)
    }

    // MARK: - Shared cells & helpers

    private func statCell(_ label: String, count: Int, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text("\(count)").font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(theme.secondaryBackground)
        .cornerRadius(6)
    }

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

    private static func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// "Jane Doe <jane@example.com>" → "Jane Doe"
    private func displayName(from sender: String) -> String {
        guard let angle = sender.firstIndex(of: "<") else { return sender }
        let name = sender[..<angle].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? sender : name
    }

    // MARK: - Actions

    private func messageContextMenu(_ message: AppleMailReader.MessageSummary) -> some View {
        Group {
            Button("Reply") { performMessageAction(id: message.id) { try await reader.reply(in: $0, id: $1, toAll: false) } }
            Button("Reply All") { performMessageAction(id: message.id) { try await reader.reply(in: $0, id: $1, toAll: true) } }
            Button("Forward") { performMessageAction(id: message.id) { try await reader.forward(in: $0, id: $1) } }
            Divider()
            Button(message.isRead ? "Mark as Unread" : "Mark as Read") { performMessageAction(id: message.id) {
                try await reader.setRead(!message.isRead, in: $0, id: $1)
            } }
            Button(message.isFlagged ? "Unflag" : "Flag") { performMessageAction(id: message.id) {
                try await reader.setFlagged(!message.isFlagged, in: $0, id: $1)
            } }
            Divider()
            Button("Archive") { performMessageAction(id: message.id) { try await reader.archive(in: $0, id: $1) } }
            Button("Move to Trash", role: .destructive) { performMessageAction(id: message.id) {
                try await reader.delete(in: $0, id: $1)
            } }
        }
    }

    /// Runs a message action against the current mailbox and refreshes the
    /// list afterwards (deletes/archives remove rows, read/flag restyle them).
    private func performMessageAction(
        id: Int? = nil,
        refreshes: Bool = true,
        action: @escaping (AppleMailReader.MailboxRef, Int) async throws -> Void
    ) {
        guard let ref = selectedMailbox else { return }
        let targetID = id ?? selectedMessageID
        guard let targetID else { return }
        Task {
            do {
                try await action(ref, targetID)
                if refreshes {
                    await loadMessages()
                    await reader.loadStructure()
                } else if refreshes == false, selectedMessageID == targetID {
                    // Reflect flag toggles without a full reload.
                    if var current = detail {
                        // detail is re-fetched on next selection; update locally
                        detail = AppleMailReader.MessageDetail(
                            subject: current.subject, sender: current.sender,
                            to: current.to, cc: current.cc, date: current.date,
                            messageID: current.messageID, content: current.content,
                            isRead: current.isRead, isFlagged: !current.isFlagged
                        )
                    }
                }
            } catch {
                mailboxError = error.localizedDescription
            }
        }
    }

    private func refreshMailbox() async {
        await reader.loadStructure()
        await loadMessages()
    }

    private func refreshAll() async {
        if mode == .mailbox {
            await refreshMailbox()
        } else {
            await service.ensureRelayRunning()
            if summary != nil, let id = selectedTrackedMessage?.messageID ?? Optional(manualMessageID) {
                await loadTracking(for: id)
            }
        }
    }

    private func getMail() async {
        mailboxError = nil
        do {
            try await reader.checkForNewMail()
            try? await Task.sleep(for: .seconds(2))
            await refreshMailbox()
        } catch {
            mailboxError = error.localizedDescription
        }
    }

    private func loadMessages() async {
        guard let ref = selectedMailbox else { return }
        isLoadingList = true
        defer { isLoadingList = false }
        mailboxError = nil
        do {
            messages = try await reader.loadMessages(for: ref, limit: listLimit)
        } catch {
            messages = []
            mailboxError = "Could not load messages: \(error.localizedDescription)"
        }
    }

    private func loadDetail() async {
        guard let ref = selectedMailbox, let id = selectedMessageID else {
            detail = nil
            return
        }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        do {
            detail = try await reader.loadMessageDetail(in: ref, id: id)
            if detail == nil {
                mailboxError = "Message not found (it may have moved)."
            }
        } catch {
            mailboxError = "Could not load message: \(error.localizedDescription)"
        }
    }

    private func composeInMail() async {
        func splitAddresses(_ raw: String) -> [String] {
            raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        do {
            _ = try await service.composeInMailApp(
                to: splitAddresses(composeTo),
                cc: splitAddresses(composeCC),
                subject: composeSubject,
                content: composeBody
            )
            isComposing = false
        } catch {
            mailboxError = "Mail compose failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Tracking actions

    private func inspectSelectedMessage() async {
        trackingError = nil
        isLoadingTracking = true
        defer { isLoadingTracking = false }
        do {
            let message = try await service.selectedMessage()
            selectedTrackedMessage = message
            guard let message, let messageID = message.messageID, !messageID.isEmpty else {
                if selectedTrackedMessage == nil {
                    trackingError = "No message selected in Mail (or Mail has no viewer open)."
                }
                return
            }
            manualMessageID = AppleMailService.normalizeMessageID(messageID)
            await loadTracking(for: messageID)
        } catch {
            trackingError = "Could not read Mail's selection: \(error.localizedDescription)"
        }
    }

    private func loadTracking(for messageID: String) async {
        trackingError = nil
        isLoadingTracking = true
        defer { isLoadingTracking = false }
        let normalized = AppleMailService.normalizeMessageID(messageID)
        guard !normalized.isEmpty else { return }
        guard await service.ensureRelayRunning() else {
            trackingError = "No relay reachable at \(service.relayBaseURLString) and the embedded relay failed to start."
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
            trackingError = "No tracking data for \(normalized): \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#Preview {
    MailView()
        .environment(AppleMailService.shared)
        .environment(ThemeStore())
}
