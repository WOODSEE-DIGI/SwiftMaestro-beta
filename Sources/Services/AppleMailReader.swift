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

        /// Envelope Index URL fragments identifying this unified mailbox
        /// across accounts (matched case-insensitively with LIKE %fragment%).
        var urlFragments: [String] {
            switch self {
            case .inbox: return ["/inbox"]
            case .drafts: return ["drafts"]
            case .sent: return ["sent"]
            case .junk: return ["junk", "spam"]
            case .trash: return ["trash", "deleted"]
            }
        }
    }

    /// Where a message/mailbox lives: a unified pseudo-mailbox or a concrete
    /// mailbox from the Envelope Index (identified by its ROWID). Passed to
    /// every JXA script to resolve the target.
    enum MailboxRef: Hashable, Sendable {
        case unified(UnifiedKind)
        /// A concrete mailbox row from the Envelope Index.
        case sql(id: Int64, name: String)

        var displayName: String {
            switch self {
            case .unified(let kind): return kind.title
            case .sql(_, let name): return name
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

    // MARK: - Message list (JXA fallback — primary path is MailEnvelopeIndex)

    /// Fetches the newest `limit` messages of a mailbox (summaries only).
    ///
    /// NOTE: Mail's element order is NEWEST FIRST, and JXA by-range
    /// specifiers (`slice`) throw "Invalid index" — so this iterates indices
    /// directly. That means ~6 Apple Events per message: fine as a fallback
    /// for small limits, but the Envelope Index (SQL) is the primary list
    /// source precisely because this doesn't scale.
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
            const out = []
            const upper = Math.min(limit, n)
            for (let i = 0; i < upper; i++) {  // newest-first ordering
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
                } catch (e) {}
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
        return summaries.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    // MARK: - Message body

    /// Fetches one message's full headers + body by its global message id
    /// (matches the Envelope Index `global_message_id`). `mailboxPathHint`
    /// (display name of the mailbox the row came from) lets the resolver try
    /// the right mailbox first instead of scanning every account mailbox.
    /// Marks the message read, like viewing it in Mail.app does.
    func loadMessageDetail(globalID: Int, mailboxPathHint: String?) async throws -> MessageDetail? {
        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            const m = findMessage(Mail, parseInt(argv[0]), argv[1])
            if (!m) return 'null'
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

        \(Self.findMessageJS)
        """
        let output = try await AppleScriptRunner.run(
            script, arguments: [String(globalID), mailboxPathHint ?? ""]
        )
        guard output != "null", let data = output.data(using: .utf8) else { return nil }
        return try Self.messageDecoder.decode(MessageDetail.self, from: data)
    }

    // MARK: - Actions

    func setRead(_ read: Bool, globalID: Int, mailboxPathHint: String?) async throws {
        try await runActionScript(
            body: "m.readStatus = \(read)",
            globalID: globalID, mailboxPathHint: mailboxPathHint
        )
    }

    func setFlagged(_ flagged: Bool, globalID: Int, mailboxPathHint: String?) async throws {
        try await runActionScript(
            body: "m.flaggedStatus = \(flagged)",
            globalID: globalID, mailboxPathHint: mailboxPathHint
        )
    }

    /// Moves the message to the trash (Mail.app semantics).
    func delete(globalID: Int, mailboxPathHint: String?) async throws {
        try await runActionScript(
            body: "Mail.delete(m)",
            globalID: globalID, mailboxPathHint: mailboxPathHint
        )
    }

    /// Moves the message to the account's Archive mailbox.
    func archive(globalID: Int, mailboxPathHint: String?) async throws {
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
            globalID: globalID, mailboxPathHint: mailboxPathHint
        )
    }

    /// Opens a reply draft window in Mail.app.
    func reply(globalID: Int, mailboxPathHint: String?, toAll: Bool) async throws {
        try await runActionScript(
            body: "Mail.reply(m, { openingWindow: true, replyToAll: \(toAll) })",
            globalID: globalID, mailboxPathHint: mailboxPathHint
        )
    }

    /// Opens a forward draft window in Mail.app.
    func forward(globalID: Int, mailboxPathHint: String?) async throws {
        try await runActionScript(
            body: "Mail.forward(m, { openingWindow: true })",
            globalID: globalID, mailboxPathHint: mailboxPathHint
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

    /// Shared mailbox resolver for the (fallback) list fetch: unified
    /// pseudo-mailbox by kind, or account mailbox by names.
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
            if (accountName && accountName.length > 0) {
                return Mail.accounts.byName(accountName).mailboxes.byName(mailboxName)
            }
            // No account given: first mailbox with this name across accounts.
            for (const acct of Mail.accounts()) {
                for (const mb of acct.mailboxes()) {
                    if (mb.name() === mailboxName) return mb
                }
            }
            return null
        } catch (e) {
            return null
        }
    }
    """

    /// Locates one message by global id: the hinted mailbox name across all
    /// accounts first, then every mailbox as a fallback. whose-by-id is fast
    /// on a healthy Mail (short-circuits at the first match).
    private static let findMessageJS = """
    function findMessage(Mail, globalID, hint) {
        if (hint && hint.length > 0) {
            for (const acct of Mail.accounts()) {
                for (const mb of acct.mailboxes()) {
                    if (mb.name() === hint) {
                        try {
                            const found = mb.messages.whose({ id: globalID })
                            if (found.length) return found[0]
                        } catch (e) {}
                    }
                }
            }
        }
        for (const acct of Mail.accounts()) {
            for (const mb of acct.mailboxes()) {
                try {
                    const found = mb.messages.whose({ id: globalID })
                    if (found.length) return found[0]
                } catch (e) {}
            }
        }
        return null
    }
    """

    /// Runs a script that locates one message by global id and applies `body`
    /// to it as `m`.
    private func runActionScript(body: String, globalID: Int, mailboxPathHint: String?) async throws {
        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            const m = findMessage(Mail, parseInt(argv[0]), argv[1])
            if (!m) throw new Error('Message not found (id \(globalID))')
            \(body)
            return 'ok'
        }

        \(Self.findMessageJS)
        """
        _ = try await AppleScriptRunner.run(
            script, arguments: [String(globalID), mailboxPathHint ?? ""]
        )
    }

    private func refParts(_ ref: MailboxRef) -> (kind: String, unified: String, account: String, mailbox: String) {
        switch ref {
        case .unified(let kind):
            return ("unified", kind.rawValue, "", "")
        case .sql(_, let name):
            // The JXA fallback path resolves SQL-backed mailboxes by display
            // name across accounts (same matching the hint resolver uses).
            return ("account", "", "", name)
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
