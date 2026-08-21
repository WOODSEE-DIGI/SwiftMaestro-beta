import Foundation
import GRDB

// MARK: - Blocky Investigation Database
//
// GRDB/WAL persistence for blockchain investigations. Stores wallets,
// transactions, entity tags, and investigative notes. Follows the same
// patterns as DAMDatabase/MaestroDBDatabase.

enum BlockyDatabaseError: Error, Sendable {
    case migrationFailed(String)
}

final class BlockyDatabase: Sendable {

    static let shared: BlockyDatabase = {
        do {
            return try BlockyDatabase(open: BlockyDatabase.defaultURL())
        } catch {
            NSLog("[Blocky] Failed to open database: %@ — using in-memory fallback.",
                  String(describing: error))
            // swiftlint:disable:next force_try
            return try! BlockyDatabase(open: BlockyDatabase.inMemoryURL())
        }
    }()

    let dbQueue: DatabaseQueue

    private static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro/Blocky", isDirectory: true)
            .appendingPathComponent("investigations.sqlite")
    }

    private static func inMemoryURL() -> URL {
        URL(fileURLWithPath: "/dev/null") // GRDB in-memory fallback
    }

    private init(open url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if dir.path != "/dev/null" {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        if url.path == "/dev/null" {
            dbQueue = try DatabaseQueue()
        } else {
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
        }
        try Self.migrator.migrate(dbQueue)
    }

    // MARK: - Migrations

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-schema") { db in
            // Investigations — named cases
            try db.create(table: "investigation") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Watched wallets — addresses under investigation
            try db.create(table: "watched_wallet") { t in
                t.column("id", .text).primaryKey()
                t.column("investigation_id", .text).notNull()
                    .references("investigation", onDelete: .cascade)
                t.column("address", .text).notNull()
                t.column("chain", .text).notNull()  // "BTC" or "ETH"
                t.column("user_label", .text)        // user-assigned label
                t.column("entity_label", .text)       // known entity (exchange, mixer)
                t.column("notes", .text)
                t.column("balance", .double)
                t.column("tx_count", .integer)
                t.column("added_at", .text).notNull()
                t.column("last_checked", .text)
                t.column("is_flagged", .integer).notNull().defaults(to: 0)
                t.column("flag_reason", .text)
            }

            // Fetched transactions — deduplicated by hash+chain
            try db.create(table: "transaction") { t in
                t.column("tx_hash", .text).notNull()
                t.column("chain", .text).notNull()
                t.column("block_height", .integer)
                t.column("timestamp", .text)
                t.column("from_address", .text).notNull()
                t.column("to_address", .text).notNull()
                t.column("value", .double).notNull()
                t.column("fee", .double)
                t.column("fetched_at", .text).notNull()
                t.primaryKey(["tx_hash", "chain"])
            }

            // Wallet links — discovered connections between wallets
            try db.create(table: "wallet_link") { t in
                t.column("id", .text).primaryKey()
                t.column("from_address", .text).notNull()
                t.column("to_address", .text).notNull()
                t.column("chain", .text).notNull()
                t.column("tx_hash", .text)
                t.column("link_type", .text).notNull()  // "direct_transfer", "shared_counterparty"
                t.column("total_value", .double)
                t.column("tx_count", .integer).notNull().defaults(to: 1)
                t.column("first_seen", .text)
                t.column("last_seen", .text)
                t.column("notes", .text)
                t.column("created_at", .text).notNull()
            }

            // Entity tags — labels for addresses
            try db.create(table: "entity_tag") { t in
                t.column("id", .text).primaryKey()
                t.column("address", .text).notNull()
                t.column("chain", .text).notNull()
                t.column("tag", .text).notNull()
                t.column("category", .text)   // "exchange", "mixer", "sanctioned", "individual"
                t.column("source", .text).notNull()  // "built_in", "user", "agent"
                t.column("created_at", .text).notNull()
            }

            // Investigation notes — freeform analyst notes
            try db.create(table: "investigation_note") { t in
                t.column("id", .text).primaryKey()
                t.column("investigation_id", .text).notNull()
                    .references("investigation", onDelete: .cascade)
                t.column("content", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "user")  // "user" or agent name
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Indexes for query performance
            try db.create(index: "idx_watched_wallet_investigation",
                          on: "watched_wallet", columns: ["investigation_id"])
            try db.create(index: "idx_watched_wallet_address",
                          on: "watched_wallet", columns: ["address", "chain"])
            try db.create(index: "idx_transaction_addresses",
                          on: "transaction", columns: ["from_address", "to_address"])
            try db.create(index: "idx_wallet_link_addresses",
                          on: "wallet_link", columns: ["from_address", "to_address"])
            try db.create(index: "idx_entity_tag_address",
                          on: "entity_tag", columns: ["address", "chain"])
        }

        return migrator
    }()

    // MARK: - Investigation CRUD

    func createInvestigation(name: String, description: String?) throws -> BlockyInvestigation {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let investigation = BlockyInvestigation(
            id: id, name: name, description: description,
            createdAt: now, updatedAt: now)
        try dbQueue.write { db in
            try investigation.insert(db)
        }
        return investigation
    }

    func listInvestigations() throws -> [BlockyInvestigation] {
        try dbQueue.read { db in
            try BlockyInvestigation.order(Column("updated_at").desc).fetchAll(db)
        }
    }

    func deleteInvestigation(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM investigation WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Watched Wallet CRUD

    func addWallet(
        address: String, chain: String,
        investigationId: String,
        userLabel: String? = nil,
        entityLabel: String? = nil
    ) throws -> BlockyWatchedWallet {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let wallet = BlockyWatchedWallet(
            id: id, investigationId: investigationId,
            address: address, chain: chain,
            userLabel: userLabel, entityLabel: entityLabel,
            notes: nil, balance: nil, txCount: nil,
            addedAt: now, lastChecked: nil,
            isFlagged: false, flagReason: nil)
        try dbQueue.write { db in
            try wallet.insert(db)
        }
        return wallet
    }

    func removeWallet(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM watched_wallet WHERE id = ?", arguments: [id])
        }
    }

    func listWallets(investigationId: String) throws -> [BlockyWatchedWallet] {
        try dbQueue.read { db in
            try BlockyWatchedWallet
                .filter(Column("investigation_id") == investigationId)
                .order(Column("added_at").desc)
                .fetchAll(db)
        }
    }

    func allWatchedAddresses() throws -> [(address: String, chain: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db,
                sql: "SELECT DISTINCT address, chain FROM watched_wallet")
            return rows.map { (address: $0["address"], chain: $0["chain"]) }
        }
    }

    func updateWalletBalance(address: String, chain: String, balance: Double, txCount: Int) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE watched_wallet
                SET balance = ?, tx_count = ?, last_checked = ?
                WHERE address = ? AND chain = ?
                """, arguments: [balance, txCount, now, address, chain])
        }
    }

    func flagWallet(id: String, reason: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE watched_wallet SET is_flagged = 1, flag_reason = ?
                WHERE id = ?
                """, arguments: [reason, id])
        }
    }

    func unflagWallet(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE watched_wallet SET is_flagged = 0, flag_reason = NULL
                WHERE id = ?
                """, arguments: [id])
        }
    }

    // MARK: - Transaction CRUD

    func upsertTransaction(_ tx: BlockyTransactionRecord) throws {
        try dbQueue.write { db in
            try tx.save(db)
        }
    }

    func upsertTransactions(_ txs: [BlockyTransactionRecord]) throws {
        try dbQueue.write { db in
            for tx in txs {
                try tx.save(db)
            }
        }
    }

    func transactionsForWallet(address: String, limit: Int = 100) throws -> [BlockyTransactionRecord] {
        try dbQueue.read { db in
            try BlockyTransactionRecord
                .filter(Column("from_address") == address || Column("to_address") == address)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func transactionsBetween(addressA: String, addressB: String) throws -> [BlockyTransactionRecord] {
        try dbQueue.read { db in
            try BlockyTransactionRecord
                .filter(
                    (Column("from_address") == addressA && Column("to_address") == addressB) ||
                    (Column("from_address") == addressB && Column("to_address") == addressA)
                )
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Wallet Links

    func addLink(
        fromAddress: String, toAddress: String, chain: String,
        txHash: String? = nil, linkType: String,
        totalValue: Double? = nil, txCount: Int = 1,
        firstSeen: String? = nil, lastSeen: String? = nil
    ) throws -> BlockyWalletLink {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let link = BlockyWalletLink(
            id: id, fromAddress: fromAddress, toAddress: toAddress,
            chain: chain, txHash: txHash, linkType: linkType,
            totalValue: totalValue, txCount: txCount,
            firstSeen: firstSeen, lastSeen: lastSeen,
            notes: nil, createdAt: now)
        try dbQueue.write { db in
            try link.insert(db)
        }
        return link
    }

    func linksForWallet(address: String) throws -> [BlockyWalletLink] {
        try dbQueue.read { db in
            try BlockyWalletLink
                .filter(Column("from_address") == address || Column("to_address") == address)
                .order(Column("last_seen").desc)
                .fetchAll(db)
        }
    }

    func sharedCounterparties(addresses: [String]) throws -> [String: Int] {
        guard !addresses.isEmpty else { return [:] }
        let placeholders = addresses.map { _ in "?" }.joined(separator: ",")
        return try dbQueue.read { db in
            // Find addresses that appear as counterparties to multiple watched wallets
            let rows = try Row.fetchAll(db, sql: """
                SELECT counterparty, COUNT(DISTINCT wallet) as wallet_count FROM (
                    SELECT to_address as counterparty, from_address as wallet
                    FROM transaction WHERE from_address IN (\(placeholders))
                    UNION ALL
                    SELECT from_address as counterparty, to_address as wallet
                    FROM transaction WHERE to_address IN (\(placeholders))
                ) GROUP BY counterparty HAVING wallet_count > 1
                ORDER BY wallet_count DESC
                """, arguments: StatementArguments(addresses + addresses))
            return rows.reduce(into: [String: Int]()) { $0[$1["counterparty"]] = $1["wallet_count"] }
        }
    }

    // MARK: - Entity Tags

    func addTag(address: String, chain: String, tag: String, category: String?, source: String) throws {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO entity_tag (id, address, chain, tag, category, source, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, address, chain, tag, category, source, now])
        }
    }

    func tagsForAddress(address: String) throws -> [BlockyEntityTag] {
        try dbQueue.read { db in
            try BlockyEntityTag
                .filter(Column("address") == address)
                .fetchAll(db)
        }
    }

    // MARK: - Investigation Notes

    func addNote(investigationId: String, content: String, author: String) throws -> BlockyInvestigationNote {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let note = BlockyInvestigationNote(
            id: id, investigationId: investigationId,
            content: content, author: author,
            createdAt: now, updatedAt: now)
        try dbQueue.write { db in
            try note.insert(db)
        }
        return note
    }

    func notesForInvestigation(investigationId: String) throws -> [BlockyInvestigationNote] {
        try dbQueue.read { db in
            try BlockyInvestigationNote
                .filter(Column("investigation_id") == investigationId)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Export

    func exportInvestigation(id: String, format: ExportFormat) throws -> Data {
        let investigation = try dbQueue.read { db in
            try BlockyInvestigation.fetchOne(db, key: id)
        }
        guard let investigation else {
            throw BlockyDatabaseError.migrationFailed("Investigation not found")
        }
        let wallets = try listWallets(investigationId: id)
        let notes = try notesForInvestigation(investigationId: id)

        var allTransactions: [BlockyTransactionRecord] = []
        for wallet in wallets {
            let txs = try transactionsForWallet(address: wallet.address, limit: 500)
            allTransactions.append(contentsOf: txs)
        }
        // Deduplicate
        var seen = Set<String>()
        allTransactions = allTransactions.filter { tx in
            let key = "\(tx.txHash)|\(tx.chain)"
            if seen.contains(key) { return false }
            seen.insert(key); return true
        }

        let report = BlockyInvestigationReport(
            investigation: investigation,
            wallets: wallets,
            transactions: allTransactions.sorted { ($0.timestamp ?? "") > ($1.timestamp ?? "") },
            notes: notes,
            exportedAt: ISO8601DateFormatter().string(from: Date()))

        switch format {
        case .json:
            return try JSONEncoder.prettyEncoder.encode(report)
        case .csv:
            return try exportCSV(report: report)
        }
    }

    private func exportCSV(report: BlockyInvestigationReport) throws -> Data {
        var csv = "Investigation: \(report.investigation.name)\n"
        csv += "Exported: \(report.exportedAt)\n\n"

        csv += "WALLETS\n"
        csv += "Address,Chain,Label,Entity,Balance,TxCount,Flagged,FlagReason\n"
        for w in report.wallets {
            csv += "\(w.address),\(w.chain),\(w.userLabel ?? ""),\(w.entityLabel ?? ""),"
            csv += "\(w.balance ?? 0),\(w.txCount ?? 0),\(w.isFlagged),\(w.flagReason ?? "")\n"
        }

        csv += "\nTRANSACTIONS\n"
        csv += "Hash,Chain,From,To,Value,Fee,Timestamp,BlockHeight\n"
        for tx in report.transactions {
            csv += "\(tx.txHash),\(tx.chain),\(tx.fromAddress),\(tx.toAddress),"
            csv += "\(tx.value),\(tx.fee ?? 0),\(tx.timestamp ?? ""),\(tx.blockHeight ?? 0)\n"
        }

        csv += "\nNOTES\n"
        for n in report.notes {
            csv += "[\(n.createdAt)] \(n.author): \(n.content)\n"
        }

        return csv.data(using: .utf8) ?? Data()
    }
}

enum ExportFormat: String, CaseIterable {
    case json
    case csv
}

// MARK: - GRDB Records

struct BlockyInvestigation: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "investigation"

    let id: String
    let name: String
    let description: String?
    let createdAt: String
    let updatedAt: String

    /// GRDB maps CodingKeys raw values 1:1 to columns — camelCase needs snake_case here.
    enum CodingKeys: String, CodingKey {
        case id, name, description
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        // no auto-generated id; we set it before insert
    }
}

struct BlockyWatchedWallet: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "watched_wallet"

    let id: String
    let investigationId: String
    let address: String
    let chain: String
    let userLabel: String?
    let entityLabel: String?
    let notes: String?
    let balance: Double?
    let txCount: Int?
    let addedAt: String
    let lastChecked: String?
    let isFlagged: Bool
    let flagReason: String?

    enum CodingKeys: String, CodingKey {
        case id, address, chain, notes, balance
        case investigationId = "investigation_id"
        case userLabel = "user_label"
        case entityLabel = "entity_label"
        case txCount = "tx_count"
        case addedAt = "added_at"
        case lastChecked = "last_checked"
        case isFlagged = "is_flagged"
        case flagReason = "flag_reason"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct BlockyTransactionRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "transaction"

    let txHash: String
    let chain: String
    let blockHeight: Int?
    let timestamp: String?
    let fromAddress: String
    let toAddress: String
    let value: Double
    let fee: Double?
    let fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case chain, timestamp, value, fee
        case txHash = "tx_hash"
        case blockHeight = "block_height"
        case fromAddress = "from_address"
        case toAddress = "to_address"
        case fetchedAt = "fetched_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct BlockyWalletLink: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "wallet_link"

    let id: String
    let fromAddress: String
    let toAddress: String
    let chain: String
    let txHash: String?
    let linkType: String
    let totalValue: Double?
    let txCount: Int
    let firstSeen: String?
    let lastSeen: String?
    let notes: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, chain, notes
        case fromAddress = "from_address"
        case toAddress = "to_address"
        case txHash = "tx_hash"
        case linkType = "link_type"
        case totalValue = "total_value"
        case txCount = "tx_count"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct BlockyEntityTag: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "entity_tag"

    let id: String?
    let address: String
    let chain: String
    let tag: String
    let category: String?
    let source: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, address, chain, tag, category, source
        case createdAt = "created_at"
    }

    // Custom init for manual fetch (id may be absent)
    init(id: String?, address: String, chain: String, tag: String, category: String?, source: String, createdAt: String) {
        self.id = id; self.address = address; self.chain = chain
        self.tag = tag; self.category = category; self.source = source
        self.createdAt = createdAt
    }

    init(address: String, chain: String, tag: String, category: String?, source: String) {
        self.id = nil; self.address = address; self.chain = chain
        self.tag = tag; self.category = category; self.source = source
        self.createdAt = ISO8601DateFormatter().string(from: Date())
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct BlockyInvestigationNote: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "investigation_note"

    let id: String
    let investigationId: String
    let content: String
    let author: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, content, author
        case investigationId = "investigation_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

// MARK: - Report Model

struct BlockyInvestigationReport: Codable, Sendable {
    let investigation: BlockyInvestigation
    let wallets: [BlockyWatchedWallet]
    let transactions: [BlockyTransactionRecord]
    let notes: [BlockyInvestigationNote]
    let exportedAt: String
}

// MARK: - JSON Encoder

extension JSONEncoder {
    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
