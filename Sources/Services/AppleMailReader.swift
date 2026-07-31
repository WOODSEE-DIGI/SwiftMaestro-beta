import Foundation

// MARK: - Apple Mail reader (JXA bridge)

/// Reads and drives Mail.app's live data — accounts, mailboxes, message
/// lists, message bodies, and message actions — through Mail's scripting
/// dictionary, using the shared `AppleScriptRunner` JXA bridge. This lets the
/// Mail panel render a real webmail-style UI on top of Mail.app's own synced
/// store (iCloud, Gmail, ... — 100k+ messages) with no IMAP credentials or
/// sync engine of our own. When MaestroMail's transport matures, this surface
/// can be swapped for it without changing the views.
///
/// All scripts return JSON (robust string escaping for free) and run
/// off-main inside `AppleScriptRunner`. State lives on the main actor.
@Observable
@MainActor
final class AppleMailReader {
    static let shared = AppleMailReader()

    // MARK: - Model types

    /// The unified pseudo-mailboxes Mail.app exposes at the top level.
    enum UnifiedKind: String, CaseIterable, Codable, Sendable {
        case inbox, drafts, sent, junk, trash

        var title: String {
            switch self {
            case .inbox: return "All Inboxes"
            case .drafts: return "All Drafts"
            case .sent: return "All Sent"
            case .junk: return "All Junk"
            case .trash: return "All Trash"
            }
        }

        var icon: String {
            switch self {
            case .inbox: return "tray"
            case .drafts: return "doc.text"
            case .sent: return "paperplane"
            case .junk: return "bin.xmark"
            case .trash: return "trash"
            }
        }
    }

    /// Where a message/mailbox lives: a unified pseudo-mailbox or a concrete
    /// account mailbox. Passed to every JXA script to resolve the target.
    enum MailboxRef: Hashable, Sendable {
        case unified(UnifiedKind)
        case account(accountName: String, mailboxName: String)

        var displayName: String {
            switch self {
            case .unified(let kind): return kind.title
            case .account(_, let mailboxName): return mailboxName
            }
        }
    }

    struct MailboxInfo: Codable, Sendable, Hashable {
        let name: String
        let unread: Int
    }

    struct AccountInfo: Codable, Sendable, Identifiable {
        let name: String
        let mailboxes: [MailboxInfo]
        var id: String { name }
    }

    struct UnifiedState: Codable, Sendable {
        let inboxUnread: Int?
        let draftsUnread: Int?
        let sentUnread: Int?
        let junkUnread: Int?
        let trashUnread: Int?

        func unread(for kind: UnifiedKind) -> Int? {
            switch kind {
            case .inbox: return inboxUnread
            case .drafts: return draftsUnread
            case .sent: return sentUnread
            case .junk: return junkUnread
            case .trash: return trashUnread
            }
        }
    }

    struct MessageSummary: Codable, Sendable, Identifiable {
        let id: Int
        let subject: String
        let sender: String
        let date: Date?
        let isRead: Bool
        let isFlagged: Bool

        enum CodingKeys: String, CodingKey {
            case id, subject, sender, date
            case isRead = "read"
            case isFlagged = "flagged"
        }
    }

    struct MessageDetail: Codable, Sendable {
        let subject: String
        let sender: String
        let to: [String]
        let cc: [String]
        let date: Date?
        let messageID: String
        let content: String
        let isRead: Bool
        let isFlagged: Bool

        enum CodingKeys: String, CodingKey {
            case subject, sender, to, cc, date, messageID, content
            case isRead = "read"
            case isFlagged = "flagged"
        }
    }

    // MARK: - Published state

    private(set) var unified: UnifiedState?
    private(set) var accounts: [AccountInfo] = []
    private(set) var isLoadingStructure = false
    private(set) var lastError: String?

    // MARK: - Structure (accounts, mailboxes, unread counts)

    /// Loads the unified unread counts plus every account and its mailboxes.
    func loadStructure() async {
        guard !isLoadingStructure else { return }
        isLoadingStructure = true
        defer { isLoadingStructure = false }
        lastError = nil

        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            const safe = fn => { try { return fn() } catch (e) { return null } }
            const result = {
                unified: {
                    inboxUnread: safe(() => Mail.inbox.unreadCount()),
                    draftsUnread: safe(() => Mail.draftsMailbox.unreadCount()),
                    sentUnread: safe(() => Mail.sentMailbox.unreadCount()),
                    junkUnread: safe(() => Mail.junkMailbox.unreadCount()),
                    trashUnread: safe(() => Mail.trashMailbox.unreadCount()),
                },
                accounts: []
            }
            for (const acct of Mail.accounts()) {
                const entry = { name: acct.name(), mailboxes: [] }
                for (const mb of acct.mailboxes()) {
                    entry.mailboxes.push({ name: mb.name(), unread: safe(() => mb.unreadCount()) || 0 })
                }
                result.accounts.push(entry)
            }
            return JSON.stringify(result)
        }
        """

        do {
            let output = try await AppleScriptRunner.run(script)
            guard let data = output.data(using: .utf8) else { return }
            let decoded = try Self.structureDecoder.decode(StructurePayload.self, from: data)
            unified = decoded.unified
            accounts = decoded.accounts
        } catch {
            lastError = error.localizedDescription
        }
    }

    private struct StructurePayload: Codable {
        let unified: UnifiedState
        let accounts: [AccountInfo]
    }

    // MARK: - Message list

    /// Fetches the newest `limit` messages of a mailbox (summaries only —
    /// subject/sender/date/flags, no bodies). Bulk JXA property fetches keep
    /// this to a handful of Apple Events even for 50+ rows.
    func loadMessages(for ref: MailboxRef, limit: Int = 50) async throws -> [MessageSummary] {
        let (kind, unified, account, mailbox) = refParts(ref)
        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            const mb = resolveMailbox(Mail, argv[0], argv[1], argv[2], argv[3])
            if (!mb) return '[]'
            const limit = parseInt(argv[4])
            const msgs = mb.messages
            const n = msgs.length
            if (n === 0) return '[]'
            const start = Math.max(0, n - limit)
            const out = []
            try {
                // Fast path: one Apple Event per property over a by-range slice.
                const slice = msgs.slice(start, n)
                const ids = slice.id()
                const subjects = slice.subject()
                const senders = slice.sender()
                const dates = slice.dateReceived()
                const reads = slice.readStatus()
                const flags = slice.flaggedStatus()
                for (let i = 0; i < ids.length; i++) {
                    out.push({
                        id: ids[i],
                        subject: subjects[i] || '(no subject)',
                        sender: senders[i] || '',
                        date: dates[i] ? dates[i].toISOString() : null,
                        read: !!reads[i],
                        flagged: !!flags[i]
                    })
                }
            } catch (e) {
                // Fallback: per-message property fetch.
                for (let i = start; i < n; i++) {
                    const m = msgs[i]
                    try {
                        const d = m.dateReceived()
                        out.push({
                            id: m.id(),
                            subject: m.subject() || '(no subject)',
                            sender: m.sender() || '',
                            date: d ? d.toISOString() : null,
                            read: !!m.readStatus(),
                            flagged: !!m.flaggedStatus()
                        })
                    } catch (e2) {}
                }
            }
            return JSON.stringify(out)
        }

        \(Self.resolveMailboxJS)
        """
        let output = try await AppleScriptRunner.run(
            script, arguments: [kind, unified, account, mailbox, String(limit)]
        )
        guard let data = output.data(using: .utf8) else { return [] }
        let summaries = try Self.messageDecoder.decode([MessageSummary].self, from: data)
        // Newest first regardless of Mail's on-disk ordering.
        return summaries.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - Message body

    /// Fetches one message's full headers + body. Marks it read (like viewing
    /// it in Mail.app does).
    func loadMessageDetail(in ref: MailboxRef, id: Int) async throws -> MessageDetail? {
        let (kind, unified, account, mailbox) = refParts(ref)
        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            const mb = resolveMailbox(Mail, argv[0], argv[1], argv[2], argv[3])
            if (!mb) return 'null'
            const found = mb.messages.whose({ id: parseInt(argv[4]) })
            if (found.length === 0) return 'null'
            const m = found[0]
            const d = m.dateReceived()
            const result = {
                subject: m.subject() || '(no subject)',
                sender: m.sender() || '',
                to: m.toRecipients().map(r => r.address()),
                cc: m.ccRecipients().map(r => r.address()),
                date: d ? d.toISOString() : null,
                messageID: m.messageId() || '',
                content: m.content() || '',
                read: !!m.readStatus(),
                flagged: !!m.flaggedStatus()
            }
            if (!result.read) {
                try { m.readStatus = true } catch (e) {}
                result.read = true
            }
            return JSON.stringify(result)
        }

        \(Self.resolveMailboxJS)
        """
        let output = try await AppleScriptRunner.run(
            script, arguments: [kind, unified, account, mailbox, String(id)]
        )
        guard output != "null", let data = output.data(using: .utf8) else { return nil }
        return try Self.messageDecoder.decode(MessageDetail.self, from: data)
    }

    // MARK: - Actions

    func setRead(_ read: Bool, in ref: MailboxRef, id: Int) async throws {
        try await runActionScript(
            body: "m.readStatus = \(read)",
            ref: ref, id: id
        )
    }

    func setFlagged(_ flagged: Bool, in ref: MailboxRef, id: Int) async throws {
        try await runActionScript(
            body: "m.flaggedStatus = \(flagged)",
            ref: ref, id: id
        )
    }

    /// Moves the message to the trash (Mail.app semantics).
    func delete(in ref: MailboxRef, id: Int) async throws {
        try await runActionScript(body: "Mail.delete(m)", ref: ref, id: id)
    }

    /// Moves the message to the account's Archive mailbox.
    func archive(in ref: MailboxRef, id: Int) async throws {
        try await runActionScript(
            body: """
            const acct = m.mailbox().account()
            let target = null
            for (const b of acct.mailboxes()) {
                if (b.name().toLowerCase() === 'archive') { target = b; break }
            }
            if (!target) throw new Error('No Archive mailbox on this account')
            Mail.move(m, { to: target })
            """,
            ref: ref, id: id
        )
    }

    /// Opens a reply draft window in Mail.app.
    func reply(in ref: MailboxRef, id: Int, toAll: Bool) async throws {
        try await runActionScript(
            body: "Mail.reply(m, { openingWindow: true, replyToAll: \(toAll) })",
            ref: ref, id: id
        )
    }

    /// Opens a forward draft window in Mail.app.
    func forward(in ref: MailboxRef, id: Int) async throws {
        try await runActionScript(
            body: "Mail.forward(m, { openingWindow: true })",
            ref: ref, id: id
        )
    }

    /// Triggers "check for new mail" in Mail.app.
    func checkForNewMail() async throws {
        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            Mail.checkForNewMail()
            return 'ok'
        }
        """
        _ = try await AppleScriptRunner.run(script)
    }

    // MARK: - JXA plumbing

    /// Shared mailbox resolver used by every script: unified pseudo-mailbox
    /// by kind, or account mailbox by names.
    private static let resolveMailboxJS = """
    function resolveMailbox(Mail, kind, unifiedName, accountName, mailboxName) {
        if (kind === 'unified') {
            const map = {
                inbox: Mail.inbox,
                drafts: Mail.draftsMailbox,
                sent: Mail.sentMailbox,
                junk: Mail.junkMailbox,
                trash: Mail.trashMailbox,
            }
            return map[unifiedName] || null
        }
        try {
            return Mail.accounts.byName(accountName).mailboxes.byName(mailboxName)
        } catch (e) {
            return null
        }
    }
    """

    /// Runs a script that locates one message and applies `body` to it as `m`.
    private func runActionScript(body: String, ref: MailboxRef, id: Int) async throws {
        let (kind, unified, account, mailbox) = refParts(ref)
        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            const mb = resolveMailbox(Mail, argv[0], argv[1], argv[2], argv[3])
            if (!mb) throw new Error('Mailbox not found')
            const found = mb.messages.whose({ id: parseInt(argv[4]) })
            if (found.length === 0) throw new Error('Message not found')
            const m = found[0]
            \(body)
            return 'ok'
        }

        \(Self.resolveMailboxJS)
        """
        _ = try await AppleScriptRunner.run(
            script, arguments: [kind, unified, account, mailbox, String(id)]
        )
    }

    private func refParts(_ ref: MailboxRef) -> (kind: String, unified: String, account: String, mailbox: String) {
        switch ref {
        case .unified(let kind):
            return ("unified", kind.rawValue, "", "")
        case .account(let accountName, let mailboxName):
            return ("account", "", accountName, mailboxName)
        }
    }

    // MARK: - Decoders

    /// JXA `Date#toISOString()` includes milliseconds.
    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let messageDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = iso8601WithFraction.date(from: string) { return date }
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unparseable date: \(string)")
        }
        return decoder
    }()

    private static let structureDecoder = JSONDecoder()
}
