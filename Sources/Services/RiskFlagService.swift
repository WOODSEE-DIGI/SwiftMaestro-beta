import Foundation
import GRDB

// MARK: - Risk Flag Service

/// Shared service that computes contact fingerprints and checks them against
/// local reports and (eventually) the p2p blacklist network.
///
/// This service is backend-agnostic: it works with any contact-shaped entity
/// that has a name and an optional tax identifier. MaestroBooks clients and
/// suppliers, ContactCard profiles, and any future CRM entity can all use it.
///
/// The service is MainActor-bound so views can call it synchronously; import
/// flows that run off-main must hop to MainActor before querying.
@MainActor
@Observable
final class RiskFlagService {
    static let shared = RiskFlagService()

    private let dbQueue: DatabaseQueue
    private var flags: [String: RiskFlag] = [:]

    /// Whether the user has opted in to p2p flag lookups.
    var p2pEnabled: Bool {
        get { LocaleSettings.shared.p2pBlacklistEnabled }
        set { LocaleSettings.shared.p2pBlacklistEnabled = newValue }
    }

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SwiftMaestro", isDirectory: true) ?? URL(fileURLWithPath: "/tmp")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("riskflags.sqlite")
        dbQueue = try! DatabaseQueue(path: path.path)
        try? dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS risk_flags (
                    fingerprint TEXT PRIMARY KEY,
                    severity TEXT NOT NULL,
                    report_count INTEGER NOT NULL,
                    last_reported REAL NOT NULL,
                    source TEXT NOT NULL,
                    reason TEXT NOT NULL
                )
                """)
        }
        Task { await loadLocalFlags() }
    }

    // MARK: - Local cache

    func loadLocalFlags() async {
        do {
            let rows = try await dbQueue.read { db in
                try RiskFlag.fetchAll(db)
            }
            flags = Dictionary(uniqueKeysWithValues: rows.map { ($0.fingerprint, $0) })
        } catch {
            flags = [:]
        }
    }

    func upsert(_ flag: RiskFlag) async throws {
        try await dbQueue.write { db in
            try flag.save(db)
        }
        await loadLocalFlags()
    }

    func remove(fingerprint: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM risk_flags WHERE fingerprint = ?", arguments: [fingerprint])
        }
        await loadLocalFlags()
    }

    // MARK: - Queries

    /// Looks up the flag for a single contact.
    func flag(for name: String, taxID: String?, country: String? = nil) -> RiskFlag? {
        let resolved = country ?? LocaleSettings.shared.country
        let fingerprint = ContactFingerprint.make(name: name, taxID: taxID, country: resolved)
        return flags[fingerprint]
    }

    /// Checks a batch of contacts and returns only those that are flagged.
    /// Used during bulk imports.
    func flaggedContacts(in contacts: [(name: String, taxID: String?, country: String?)]) async -> [RiskFlag] {
        if p2pEnabled {
            await refreshFromNetwork(for: contacts)
        }
        return contacts.compactMap {
            flag(for: $0.name, taxID: $0.taxID, country: $0.country)
        }
    }

    /// Computes severity from an invoice reminder / report.
    static func severity(for daysOverdue: Int, reportCount: Int = 1) -> RiskFlag.Severity {
        switch daysOverdue {
        case ..<30:  return .info
        case 30..<60: return .low
        case 60..<90: return .medium
        case 90..<120: return .high
        default: return .critical
        }
    }

    // MARK: - Report creation

    /// Creates a local flag from a reported unpaid invoice. The actual invoice
    /// details stay in MaestroBooks; only the fingerprint and severity land here.
    func reportLocal(name: String, taxID: String?, country: String? = nil, daysOverdue: Int) async throws {
        let resolved = country ?? LocaleSettings.shared.country
        let fingerprint = ContactFingerprint.make(name: name, taxID: taxID, country: resolved)
        let severity = Self.severity(for: daysOverdue)
        let existing = flag(for: name, taxID: taxID, country: resolved)
        let flag = RiskFlag(
            fingerprint: fingerprint,
            severity: max(existing?.severity ?? .info, severity),
            reportCount: (existing?.reportCount ?? 0) + 1,
            lastReported: Date(),
            source: .local,
            reason: "Unpaid invoice \(daysOverdue) days overdue")
        try await upsert(flag)
    }

    // MARK: - Network (stubs for p2p integration)

    private func refreshFromNetwork(for contacts: [(name: String, taxID: String?, country: String?)]) async {
        // TODO: replace with real p2p/verifier query.
        // For now this is a no-op so the feature works entirely offline.
    }
}

extension RiskFlag.Severity: Comparable {
    static func < (lhs: RiskFlag.Severity, rhs: RiskFlag.Severity) -> Bool {
        let order: [RiskFlag.Severity] = [.info, .low, .medium, .high, .critical]
        guard let li = order.firstIndex(of: lhs), let ri = order.firstIndex(of: rhs) else { return false }
        return li < ri
    }
}

// GRDB conformance for RiskFlag
extension RiskFlag: FetchableRecord, PersistableRecord {
    static let databaseTableName = "risk_flags"

    init(row: Row) throws {
        fingerprint = row["fingerprint"]
        severity = RiskFlag.Severity(rawValue: row["severity"]) ?? .info
        reportCount = row["report_count"]
        lastReported = Date(timeIntervalSince1970: row["last_reported"])
        source = RiskFlag.Source(rawValue: row["source"]) ?? .local
        reason = row["reason"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["fingerprint"] = fingerprint
        container["severity"] = severity.rawValue
        container["report_count"] = reportCount
        container["last_reported"] = lastReported.timeIntervalSince1970
        container["source"] = source.rawValue
        container["reason"] = reason
    }
}
