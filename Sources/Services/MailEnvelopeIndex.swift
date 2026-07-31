import Foundation
import GRDB

// MARK: - Mail Envelope Index reader

/// Reads Apple Mail's Envelope Index (the SQLite database backing Mail.app's
/// message lists) directly — no Apple Events involved.
///
/// Why this exists: JXA/AppleScript against Mail.app does not scale to large
/// stores (a single bulk property fetch over a 127k-message inbox takes ~7s;
/// repeated events can wedge Mail's event queue entirely). The same query
/// against the Envelope Index takes single-digit milliseconds, works while
/// Mail is busy or dialog-blocked, and gives real SQL pagination + search.
///
/// Read-only. If the file can't be opened (TCC prompt denied, layout
/// changed), `isAvailable` stays false and callers fall back to the JXA
/// bridge (`AppleMailReader`).
@Observable
@MainActor
final class MailEnvelopeIndex {
    static let shared = MailEnvelopeIndex()

    // MARK: - Row types

    struct MailboxRow: Identifiable, Hashable, Sendable {
        /// messages.mailbox foreign key.
        let id: Int64
        let url: String
        let totalCount: Int
        let unreadCount: Int

        /// The account UUID segment of the mailbox URL.
        var accountUUID: String {
            // imap://UUID/path… or local://UUID/…
            guard let schemeEnd = url.range(of: "://") else { return url }
            let rest = url[schemeEnd.upperBound...]
            return rest.split(separator: "/").first.map(String.init) ?? url
        }

        /// Percent-decoded display path, e.g. "TAX 2022-2023" or "[Gmail]/All Mail".
        var displayPath: String {
            guard let schemeEnd = url.range(of: "://") else { return url }
            let rest = String(url[schemeEnd.upperBound...])
            let path = rest.split(separator: "/").dropFirst().joined(separator: "/")
            return path.removingPercentEncoding ?? path
        }

        var displayName: String {
            displayPath.split(separator: "/").last.map(String.init) ?? displayPath
        }
    }

    struct MessageRow: Identifiable, Sendable {
        /// Mail's global message id — matches the AppleScript `id` property,
        /// so JXA body fetches / actions can address this exact message.
        let id: Int
        let subject: String
        let senderAddress: String
        let senderName: String
        let date: Date
        let isRead: Bool
        let isFlagged: Bool
        let mailboxURL: String

        var senderDisplay: String {
            senderName.isEmpty ? senderAddress : senderName
        }
    }

    // MARK: - State

    private(set) var isAvailable = false
    private(set) var lastError: String?

    /// True when the failure looks like TCC denying access to Mail's data
    /// folder (SQLite AUTH/CANTOPEN from EPERM/EACCES). The only remedy on
    /// modern macOS is Full Disk Access — there is no narrower public
    /// permission for ~/Library/Mail.
    private(set) var needsFullDiskAccess = false

    private var dbQueue: DatabaseQueue?

    private static var indexURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mail/V10/MailData/Envelope Index")
    }

    // MARK: - Open

    /// Opens the index read-only (WAL-safe). Idempotent.
    @discardableResult
    func open() -> Bool {
        if dbQueue != nil { return isAvailable }
        do {
            var configuration = Configuration()
            configuration.readonly = true
            dbQueue = try DatabaseQueue(path: Self.indexURL.path, configuration: configuration)
            // Prove the schema is what we expect before declaring availability.
            try dbQueue?.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
            }
            isAvailable = true
            lastError = nil
        } catch {
            dbQueue = nil
            isAvailable = false
            lastError = error.localizedDescription
            needsFullDiskAccess = Self.looksLikeAccessDenied(error)
        }
        return isAvailable
    }

    /// SQLite error 23 (AUTH) or 14 (CANTOPEN with an underlying EPERM) are
    /// how TCC denial surfaces through GRDB; NSFileReadNoPermission (257) is
    /// the Foundation equivalent.
    private static func looksLikeAccessDenied(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        if description.contains("authorization denied")
            || description.contains("authorisation denied")
            || description.contains("sqlite error 23")
            || description.contains("error 23")
            || description.contains("operation not permitted")
            || description.contains("eperm") {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == 257 { return true }
        // GRDB wraps SQLite errors with the code in the message.
        if description.contains("cantopen") || description.contains("can't open") { return true }
        return false
    }

    // MARK: - Mailboxes

    /// Every mailbox with message counts, ordered by account then path.
    func mailboxes() throws -> [MailboxRow] {
        guard let dbQueue else { throw EnvelopeIndexError.notOpen }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ROWID, url, total_count, unread_count
                FROM mailboxes
                ORDER BY url
                """)
            return rows.map {
                MailboxRow(
                    id: $0["ROWID"],
                    url: $0["url"],
                    totalCount: $0["total_count"],
                    unreadCount: $0["unread_count"]
                )
            }
        }
    }

    // MARK: - Messages

    /// The newest `limit` non-deleted messages in any of the given mailbox
    /// ROWIDs (nil = all mailboxes), offset for pagination, with optional
    /// SQL-side search over subject and sender. Ordered newest-first.
    func messages(
        mailboxIDs: [Int64]?,
        search: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> [MessageRow] {
        guard let dbQueue else { throw EnvelopeIndexError.notOpen }

        var sql = """
            SELECT m.global_message_id AS globalID,
                   COALESCE(s.subject, '(no subject)') AS subject,
                   COALESCE(a.address, '') AS senderAddress,
                   COALESCE(a.comment, '') AS senderName,
                   m.date_received AS dateReceived,
                   m.read AS isRead,
                   m.flagged AS isFlagged,
                   mb.url AS mailboxURL
            FROM messages m
            LEFT JOIN subjects s ON s.ROWID = m.subject
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN mailboxes mb ON mb.ROWID = m.mailbox
            WHERE m.deleted = 0
            """
        var arguments: [(any DatabaseValueConvertible)?] = []

        if let mailboxIDs, !mailboxIDs.isEmpty {
            let placeholders = mailboxIDs.map { _ in "?" }.joined(separator: ",")
            sql += " AND m.mailbox IN (\(placeholders))"
            arguments += mailboxIDs.map { $0 as (any DatabaseValueConvertible)? }
        }
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += " AND (s.subject LIKE ? OR a.address LIKE ? OR a.comment LIKE ?)"
            let pattern = "%\(search)%"
            arguments += [pattern, pattern, pattern]
        }
        sql += " ORDER BY m.date_received DESC LIMIT ? OFFSET ?"
        arguments += [limit, offset]

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map { row in
                MessageRow(
                    id: row["globalID"],
                    subject: row["subject"],
                    senderAddress: row["senderAddress"],
                    senderName: row["senderName"],
                    date: Date(timeIntervalSince1970: row["dateReceived"]),
                    isRead: row["isRead"] != 0,
                    isFlagged: row["isFlagged"] != 0,
                    mailboxURL: row["mailboxURL"] ?? ""
                )
            }
        }
    }

    /// Mailbox ROWIDs whose URL matches any of the given case-insensitive
    /// path fragments (used for the unified Favourites pseudo-mailboxes:
    /// "%/inbox", "drafts", "sent", "junk"/"spam", "trash"/"deleted").
    func mailboxIDs(matchingFragments fragments: [String]) throws -> [Int64] {
        guard let dbQueue else { throw EnvelopeIndexError.notOpen }
        let clauses = fragments.map { _ in "LOWER(url) LIKE ?" }.joined(separator: " OR ")
        let patterns: [(any DatabaseValueConvertible)?] = fragments.map { "%\($0.lowercased())%" }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT ROWID FROM mailboxes WHERE \(clauses)",
                arguments: StatementArguments(patterns)
            )
            return rows.map { $0["ROWID"] as Int64 }
        }
    }

    // MARK: - Errors

    enum EnvelopeIndexError: LocalizedError {
        case notOpen

        var errorDescription: String? {
            "Mail's Envelope Index is not open."
        }
    }
}
