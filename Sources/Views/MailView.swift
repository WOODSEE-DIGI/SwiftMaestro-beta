import SwiftUI
import AppKit

// MARK: - Mail view

/// Webmail-style Mail panel: mailbox sidebar, message list, and reading pane
/// rendered on top of Mail.app's live data (via `AppleMailReader`). Compose
/// hands drafts to Mail.app (JXA) or the default client (mailto:).
struct MailView: View {
    @Environment(AppleMailService.self) private var service
    @Environment(ThemeStore.self) private var theme
    @State private var reader = AppleMailReader.shared
    @State private var envelope = MailEnvelopeIndex.shared
    @State private var bodyStore = MailBodyStore.shared

    // Mailbox state
    @State private var selectedMailbox: AppleMailReader.MailboxRef? = .unified(.inbox)
    @State private var messages: [MailEnvelopeIndex.MessageRow] = []
    @State private var sqlMailboxes: [MailEnvelopeIndex.MailboxRow] = []
    @State private var accountSectionNames: [String: String] = [:]  // account UUID → display name
    @State private var unifiedUnread: [AppleMailReader.UnifiedKind: Int] = [:]
    @State private var selectedMessageID: Int?
    @State private var detail: AppleMailReader.MessageDetail?
    @State private var detailCache: [Int: AppleMailReader.MessageDetail] = [:]
    @State private var detailError: String?
    @State private var detailNeedsAutomation = false
    @State private var prefetchTask: Task<Void, Never>?
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var listLimit = 50
    @State private var listOffset = 0
    @State private var isLoadingList = false
    @State private var isLoadingDetail = false
    @State private var mailboxError: String?

    // Compose sheet
    @State private var isComposing = false
    @State private var composeTo = ""
    @State private var composeCC = ""
    @State private var composeSubject = ""
    @State private var composeBody = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            mailboxMode
        }
        .task {
            service.requestAuthorization()
            await refreshMailbox()
        }
        .sheet(isPresented: $isComposing) { composeSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Mail")
                .font(.headline)
            Spacer()
            Button { isComposing = true } label: {
                Label("Compose", systemImage: "square.and.pencil")
            }
            Button { Task { await getMail() } } label: {
                Label("Get Mail", systemImage: "arrow.down.circle")
            }
            Button { Task { await refreshMailbox() } } label: {
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
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 300)
            messageList
                .frame(minWidth: 200, idealWidth: 300)
            readingPane
                .frame(minWidth: 280)
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
                        unread: unifiedUnread[kind]
                    )
                    .tag(AppleMailReader.MailboxRef.unified(kind))
                }
            }
            if !groupedSQLMailboxes.isEmpty {
                Section("Accounts") {
                    ForEach(groupedSQLMailboxes, id: \.uuid) { group in
                        Section(accountSectionNames[group.uuid] ?? "Account") {
                            ForEach(group.mailboxes) { mailbox in
                                mailboxRow(
                                    title: mailbox.displayName,
                                    icon: "folder",
                                    unread: mailbox.unreadCount
                                )
                                .tag(AppleMailReader.MailboxRef.sql(id: mailbox.id, name: mailbox.displayName))
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
            detailError = nil
            listOffset = 0
            prefetchTask?.cancel()
            Task { await loadMessages() }
        }
    }

    /// SQL mailboxes grouped by account UUID, ordered by display path.
    private var groupedSQLMailboxes: [(uuid: String, mailboxes: [MailEnvelopeIndex.MailboxRow])] {
        let grouped = Dictionary(grouping: sqlMailboxes) { $0.accountUUID }
        return grouped
            .map { (uuid: $0.key, mailboxes: $0.value.sorted { $0.displayPath < $1.displayPath }) }
            .sorted { $0.uuid < $1.uuid }
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
            .onChange(of: searchText) { _, _ in
                // Debounced server-side search.
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    listOffset = 0
                    await loadMessages()
                }
            }

            Divider()

            if envelope.needsFullDiskAccess && !envelope.isAvailable {
                fullDiskAccessPrompt
            } else {
                if let mailboxError {
                    Text(mailboxError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                List(selection: $selectedMessageID) {
                    ForEach(messages) { message in
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
    }

    /// Shown when macOS privacy (TCC) blocks reads of Mail's data folder.
    /// Full Disk Access is the only public remedy; it applies at process
    /// start, so the app must be relaunched after granting.
    private var fullDiskAccessPrompt: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Full Disk Access Required")
                .font(.headline)
            Text("SwiftMaestro reads Mail's message index locally (instant lists, even while Mail is busy). "
                + "macOS blocks that folder until you grant Full Disk Access.\n\n"
                + "Enable SwiftMaestro in the list, then quit and relaunch the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Open Full Disk Access Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Retry") {
                Task { await refreshMailbox() }
            }
            .font(.caption)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func messageRow(_ message: MailEnvelopeIndex.MessageRow) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(message.isRead ? Color.clear : theme.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.senderDisplay)
                        .font(.callout.weight(message.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    if message.isFlagged {
                        Image(systemName: "flag.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(Self.dateLabel(message.date))
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
            } else if isLoadingDetail {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                Text("Loading message…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                Spacer()
            } else if let detailError {
                Spacer()
                ContentUnavailableView(
                    "Couldn't Load Message",
                    systemImage: "exclamationmark.triangle",
                    description: Text(detailError)
                )
                HStack(spacing: 12) {
                    if detailNeedsAutomation {
                        Button("Open Automation Settings") {
                            AppleMailService.openAutomationSettings()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Retry") {
                        Task { await loadDetail() }
                    }
                }
                .padding(.top, 8)
                Spacer()
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
            Button { performMessageAction { try await reader.reply(globalID: $0, mailboxPathHint: $1, toAll: false) } } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }.help("Reply")
            Button { performMessageAction { try await reader.reply(globalID: $0, mailboxPathHint: $1, toAll: true) } } label: {
                Image(systemName: "arrowshape.turn.up.left.2")
            }.help("Reply All")
            Button { performMessageAction { try await reader.forward(globalID: $0, mailboxPathHint: $1) } } label: {
                Image(systemName: "arrowshape.turn.up.right")
            }.help("Forward")
            Divider().frame(height: 16)
            Button { performMessageAction(refreshes: false) { id, hint in
                try await reader.setFlagged(!(detail?.isFlagged ?? false), globalID: id, mailboxPathHint: hint)
            } } label: {
                Image(systemName: detail?.isFlagged == true ? "flag.fill" : "flag")
            }.help(detail?.isFlagged == true ? "Unflag" : "Flag")
            Button { performMessageAction { id, hint in
                try await reader.archive(globalID: id, mailboxPathHint: hint)
            } } label: {
                Image(systemName: "archivebox")
            }.help("Archive")
            Button { performMessageAction { id, hint in
                try await reader.delete(globalID: id, mailboxPathHint: hint)
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
        let key = detail.messageID.isEmpty ? detail.subject : detail.messageID
        // MIME-truth first (body store knows the part's content type);
        // tag sniffing is only a fallback for JXA-sourced details.
        let isHTML = detail.contentIsHTML ?? Self.looksLikeHTML(detail.content)
        let remoteAllowed = loadRemoteImagesByDefault || remoteContentAllowedIDs.contains(key)
        return VStack(spacing: 0) {
            if isHTML {
                if !remoteAllowed {
                    remoteContentBanner(key: key)
                }
                // Sender-intent rendering: the email's own styling, colors,
                // and backgrounds (the "paper") — like Apple Mail. The webview
                // itself stays transparent; this white card is the paper for
                // emails that assume one, and sender backgrounds paint over it.
                MailHTMLBodyView(html: detail.content, remoteContentAllowed: remoteAllowed)
                    .background(Self.paperColor)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    )
                    .padding(12)
            } else {
                ScrollView {
                    Text(AttributedString(detail.content))
                        .font(.body)
                        .foregroundStyle(Self.paperTextColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .background(Self.paperColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
                .padding(12)
            }
        }
    }

    /// Privacy banner shown while remote subresources (images/styles/fonts —
    /// i.e. tracking pixels) are blocked for this message.
    private func remoteContentBanner(key: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.badge.arrow.down")
                .foregroundStyle(.secondary)
            Text("Remote images blocked")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Load Once") { remoteContentAllowedIDs.insert(key) }
                .font(.caption)
            Button("Always Allow") { loadRemoteImagesByDefault = true }
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.secondaryBackground)
    }

    // MARK: - HTML detection & per-message remote-content opt-in

    @State private var remoteContentAllowedIDs: Set<String> = []
    @AppStorage("appleMail.loadRemoteImages") private var loadRemoteImagesByDefault = false

    /// The "paper" card behind email bodies — white like Apple Mail's message
    /// preview, so HTML emails designed for a light page render as intended.
    nonisolated private static var paperColor: Color { Color.white }
    /// Text color for plain-text emails on the paper card.
    nonisolated private static var paperTextColor: Color { Color.black.opacity(0.85) }

    nonisolated private static func looksLikeHTML(_ content: String) -> Bool {
        // Match any common structural tag — table-only emails (no <html>/<body>
        // wrapper) must still classify as HTML.
        guard let regex = try? NSRegularExpression(
            pattern: #"</?(html|head|body|table|thead|tbody|tr|td|th|div|p|span|a|img|style|meta|link|br|hr|ul|ol|li|h[1-6]|strong|em|font|center)(\s[^>]*)?/?>"#,
            options: .caseInsensitive
        ) else { return false }
        return regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
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

    private static func dateLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Actions

    private func messageContextMenu(_ message: MailEnvelopeIndex.MessageRow) -> some View {
        Group {
            Button("Reply") { performMessageAction(id: message.id, hint: message.mailboxURL) { try await reader.reply(globalID: $0, mailboxPathHint: $1, toAll: false) } }
            Button("Reply All") { performMessageAction(id: message.id, hint: message.mailboxURL) { try await reader.reply(globalID: $0, mailboxPathHint: $1, toAll: true) } }
            Button("Forward") { performMessageAction(id: message.id, hint: message.mailboxURL) { try await reader.forward(globalID: $0, mailboxPathHint: $1) } }
            Divider()
            Button(message.isRead ? "Mark as Unread" : "Mark as Read") { performMessageAction(id: message.id, hint: message.mailboxURL) {
                try await reader.setRead(!message.isRead, globalID: $0, mailboxPathHint: $1)
            } }
            Button(message.isFlagged ? "Unflag" : "Flag") { performMessageAction(id: message.id, hint: message.mailboxURL) {
                try await reader.setFlagged(!message.isFlagged, globalID: $0, mailboxPathHint: $1)
            } }
            Divider()
            Button("Archive") { performMessageAction(id: message.id, hint: message.mailboxURL) { try await reader.archive(globalID: $0, mailboxPathHint: $1) } }
            Button("Move to Trash", role: .destructive) { performMessageAction(id: message.id, hint: message.mailboxURL) {
                try await reader.delete(globalID: $0, mailboxPathHint: $1)
            } }
        }
    }

    /// Runs a message action (JXA, by global id + mailbox hint) and refreshes
    /// the list afterwards — deletes/archives remove rows, read/flag restyle
    /// them. `hint` is the message's mailbox URL; only its display-name
    /// segment is used.
    private func performMessageAction(
        id: Int? = nil,
        hint: String = "",
        refreshes: Bool = true,
        action: @escaping (Int, String?) async throws -> Void
    ) {
        let targetID = id ?? selectedMessageID
        guard let targetID else { return }
        let pathHint = hint.split(separator: "/").last.map(String.init)
            .flatMap { $0.removingPercentEncoding }
        Task {
            do {
                try await action(targetID, pathHint)
                if refreshes {
                    await loadMessages()
                    await loadStructureCounts()
                } else if selectedMessageID == targetID, var current = detail {
                    // Reflect flag toggles without a full reload.
                    detail = AppleMailReader.MessageDetail(
                        subject: current.subject, sender: current.sender,
                        to: current.to, cc: current.cc, date: current.date,
                        messageID: current.messageID, content: current.content,
                        contentIsHTML: current.contentIsHTML,
                        isRead: current.isRead, isFlagged: !current.isFlagged
                    )
                    current = detail!
                    _ = current
                }
            } catch {
                mailboxError = error.localizedDescription
            }
        }
    }

    private func refreshMailbox() async {
        if !envelope.isAvailable {
            if !envelope.open() {
                if !envelope.needsFullDiskAccess {
                    mailboxError = "Mail's Envelope Index isn't readable: \(envelope.lastError ?? "unknown")."
                } else {
                    mailboxError = nil // the Full Disk Access prompt explains it
                }
                return
            }
        }
        mailboxError = nil
        await loadStructureCounts()
        await loadMessages()
    }

    /// Reloads sidebar mailboxes + unread badges from the Envelope Index, and
    /// resolves account section names against the JXA account list.
    private func loadStructureCounts() async {
        do {
            sqlMailboxes = try envelope.mailboxes()
            // Unified unread = sum of matching mailboxes' unread counts.
            var unread: [AppleMailReader.UnifiedKind: Int] = [:]
            for kind in AppleMailReader.UnifiedKind.allCases {
                let ids = try envelope.mailboxIDs(matchingFragments: kind.urlFragments)
                let idSet = Set(ids)
                unread[kind] = sqlMailboxes.filter { idSet.contains($0.id) }
                    .reduce(0) { $0 + $1.unreadCount }
            }
            unifiedUnread = unread
        } catch {
            mailboxError = "Envelope Index error: \(error.localizedDescription)"
        }

        // Resolve account section display names: match each SQL account
        // group's mailbox name-set against the JXA accounts' name-sets.
        if accountSectionNames.isEmpty {
            await reader.loadStructure()
            var resolved: [String: String] = [:]
            for group in groupedSQLMailboxes {
                let sqlNames = Set(group.mailboxes.map { $0.displayName })
                var best: (name: String, score: Int)? = nil
                for account in reader.accounts {
                    let jxaNames = Set(account.mailboxes.map { $0.name })
                    let score = sqlNames.intersection(jxaNames).count
                    if score > 0, score > (best?.score ?? 0) {
                        best = (account.name, score)
                    }
                }
                resolved[group.uuid] = best?.name
            }
            accountSectionNames = resolved
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
        guard envelope.isAvailable else {
            mailboxError = "Mail's Envelope Index isn't readable."
            return
        }
        isLoadingList = true
        defer { isLoadingList = false }
        mailboxError = nil
        do {
            let ids: [Int64]
            switch ref {
            case .unified(let kind):
                ids = try envelope.mailboxIDs(matchingFragments: kind.urlFragments)
            case .sql(let id, _):
                ids = [id]
            }
            let query = searchText.trimmingCharacters(in: .whitespaces)
            messages = try envelope.messages(
                mailboxIDs: ids,
                search: query.isEmpty ? nil : query,
                limit: listLimit,
                offset: listOffset
            )
            prefetchBodies()
        } catch {
            messages = []
            mailboxError = "Could not load messages: \(error.localizedDescription)"
        }
    }

    /// Gently preloads bodies for the top of the list in the background.
    /// File-backed (MailBodyStore) — no Mail.app involvement, so prefetch is
    /// both fast and unable to wedge Mail's event queue.
    private func prefetchBodies(count: Int = 8) {
        prefetchTask?.cancel()
        let rows = messages.prefix(count).filter { detailCache[$0.id] == nil }
        guard !rows.isEmpty else { return }
        prefetchTask = Task {
            for row in rows {
                if Task.isCancelled { return }
                if detailCache[row.id] != nil { continue }
                if let fetched = try? await bodyStore.detail(for: row) {
                    detailCache[row.id] = fetched
                    if selectedMessageID == row.id, detail == nil {
                        detail = fetched
                        detailError = nil
                    }
                }
            }
        }
    }

    private func loadDetail() async {
        guard let id = selectedMessageID else {
            detail = nil
            detailError = nil
            return
        }
        // Cached body wins instantly; otherwise clear the stale body so an
        // old message never shows under a new selection.
        if let cached = detailCache[id] {
            detail = cached
            detailError = nil
            return
        }
        detail = nil
        detailError = nil
        detailNeedsAutomation = false
        isLoadingDetail = true
        defer { isLoadingDetail = false }

        // Fail fast with a useful message when Mail automation is denied —
        // a JXA call would otherwise stall out the full timeout first.
        if AppleMailService.mailAutomationPermission() == .denied {
            detailError = "SwiftMaestro doesn't have permission to control Mail. Enable it under SwiftMaestro in System Settings → Privacy & Security → Automation, then relaunch the app."
            detailNeedsAutomation = true
            return
        }

        let hint = messages.first(where: { $0.id == id })?.mailboxURL
            .split(separator: "/").last.map(String.init)
            .flatMap { $0.removingPercentEncoding }

        // 1) File-backed body — reads the .emlx straight from disk. Instant
        //    and immune to Mail.app's automation state.
        if let row = messages.first(where: { $0.id == id }) {
            do {
                let fetched = try await bodyStore.detail(for: row)
                detailCache[id] = fetched
                detail = fetched
                detailError = nil
                markReadLikeMail(row: row)
                return
            } catch {
                // Fall through to the JXA fallback below.
            }
        }

        // 2) JXA fallback — needs Mail.app running and responsive.
        var lastError: Error?
        for attempt in 1...2 {
            do {
                let fetched = try await reader.loadMessageDetail(globalID: id, mailboxPathHint: hint, markRead: true)
                if let fetched {
                    detailCache[id] = fetched
                    detail = fetched
                    detailError = nil
                    // Body fetch marked it read — reflect locally.
                    if let index = messages.firstIndex(where: { $0.id == id }), !messages[index].isRead {
                        let m = messages[index]
                        messages[index] = MailEnvelopeIndex.MessageRow(
                            id: m.id, rowID: m.rowID, subject: m.subject,
                            senderAddress: m.senderAddress, senderName: m.senderName,
                            date: m.date, isRead: true, isFlagged: m.isFlagged,
                            mailboxURL: m.mailboxURL
                        )
                    }
                } else {
                    detailError = "Message not found in Mail (it may have moved)."
                }
                return
            } catch {
                lastError = error
                // One retry after a beat — Mail.app being momentarily busy is
                // the common failure, and it usually answers on the second go.
                if attempt == 1 {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, selectedMessageID == id else { return }
                }
            }
        }
        detailError = lastError?.localizedDescription ?? "Could not load message."
        if let description = lastError?.localizedDescription.lowercased(),
           description.contains("not permitted") || description.contains("not authorized") || description.contains("1743") {
            detailNeedsAutomation = true
            detailError = "macOS blocked SwiftMaestro from controlling Mail. Enable it under SwiftMaestro in System Settings → Privacy & Security → Automation, then relaunch the app."
        }
    }

    /// Mirrors Mail.app behavior: viewing a message marks it read. Done as a
    /// background JXA write (short timeout, failure ignored — the body is
    /// already on screen from the file read, so Mail's responsiveness is not
    /// on the critical path).
    private func markReadLikeMail(row: MailEnvelopeIndex.MessageRow) {
        let hint = row.mailboxURL
            .split(separator: "/").last.map(String.init)
            .flatMap { $0.removingPercentEncoding }
        Task {
            try? await reader.setRead(true, globalID: row.id, mailboxPathHint: hint)
        }
        // Reflect locally without waiting for Mail.app.
        if let index = messages.firstIndex(where: { $0.id == row.id }), !messages[index].isRead {
            let m = messages[index]
            messages[index] = MailEnvelopeIndex.MessageRow(
                id: m.id, rowID: m.rowID, subject: m.subject,
                senderAddress: m.senderAddress, senderName: m.senderName,
                date: m.date, isRead: true, isFlagged: m.isFlagged,
                mailboxURL: m.mailboxURL
            )
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

}

// MARK: - Preview

#Preview {
    MailView()
        .environment(AppleMailService.shared)
        .environment(ThemeStore())
}
