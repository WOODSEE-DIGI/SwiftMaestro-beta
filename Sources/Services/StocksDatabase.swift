import Foundation
import GRDB

// MARK: - Stocks Investigation Database
//
// GRDB/WAL persistence for stock investigations. Stores watchlist groups,
// price history, institutional holders, insider transactions, proxy/voting
// filings, and investigation notes. Same patterns as BlockyDatabase.

final class StocksDatabase: Sendable {

    static let shared: StocksDatabase = {
        do {
            return try StocksDatabase(open: StocksDatabase.defaultURL())
        } catch {
            NSLog("[Stocks] Failed to open database: %@ — using in-memory fallback.",
                  String(describing: error))
            return try! StocksDatabase(open: StocksDatabase.inMemoryURL())
        }
    }()

    let dbQueue: DatabaseQueue

    private static func defaultURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro/Stocks", isDirectory: true)
            .appendingPathComponent("investigations.sqlite")
    }

    private static func inMemoryURL() -> URL {
        URL(fileURLWithPath: "/dev/null")
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
            // Watchlist groups — named collections of tickers
            try db.create(table: "watchlist_group") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("created_at", .text).notNull()
            }

            // Tracked stocks — tickers under investigation
            try db.create(table: "tracked_stock") { t in
                t.column("id", .text).primaryKey()
                t.column("group_id", .text).notNull()
                    .references("watchlist_group", onDelete: .cascade)
                t.column("symbol", .text).notNull()
                t.column("name", .text)             // company name
                t.column("sector", .text)
                t.column("industry", .text)
                t.column("notes", .text)
                t.column("is_flagged", .integer).notNull().defaults(to: 0)
                t.column("flag_reason", .text)
                t.column("added_at", .text).notNull()
                t.column("last_checked", .text)
            }

            // Price history — daily OHLCV snapshots
            try db.create(table: "price_history") { t in
                t.column("symbol", .text).notNull()
                t.column("date", .text).notNull()     // YYYY-MM-DD
                t.column("open", .double)
                t.column("high", .double)
                t.column("low", .double)
                t.column("close", .double).notNull()
                t.column("volume", .double)
                t.column("fetched_at", .text).notNull()
                t.primaryKey(["symbol", "date"])
            }

            // Institutional holders — top shareholders
            try db.create(table: "institutional_holder") { t in
                t.column("id", .text).primaryKey()
                t.column("symbol", .text).notNull()
                t.column("holder_name", .text).notNull()
                t.column("shares_held", .double)
                t.column("percent_held", .double)
                t.column("date_reported", .text)
                t.column("change_shares", .double)    // shares change from last quarter
                t.column("change_percent", .double)
                t.column("fetched_at", .text).notNull()
            }

            // Insider transactions — SEC Form 4 data
            try db.create(table: "insider_transaction") { t in
                t.column("id", .text).primaryKey()
                t.column("symbol", .text).notNull()
                t.column("insider_name", .text).notNull()
                t.column("title", .text)              // "CEO", "CFO", "Director", etc.
                t.column("transaction_type", .text).notNull()  // "Buy", "Sell", "Option Exercise"
                t.column("shares", .double)
                t.column("price_per_share", .double)
                t.column("total_value", .double)
                t.column("shares_owned", .double)     // shares owned after transaction
                t.column("filing_date", .text)
                t.column("transaction_date", .text)
                t.column("fetched_at", .text).notNull()
            }

            // Proxy/voting filings — SEC DEF 14A data
            try db.create(table: "proxy_filing") { t in
                t.column("id", .text).primaryKey()
                t.column("symbol", .text).notNull()
                t.column("company_name", .text)
                t.column("filing_date", .text).notNull()
                t.column("accession_number", .text)
                t.column("url", .text)
                t.column("meeting_date", .text)       // annual meeting date
                t.column(" proposals", .text)          // JSON array of proposals
                t.column("vote_results", .text)        // JSON: proposal → for/against/abstain
                t.column("executive_compensation", .text) // summary
                t.column("board_members", .text)       // JSON array
                t.column("fetched_at", .text).notNull()
            }

            // Investigation notes — analyst annotations
            try db.create(table: "stock_note") { t in
                t.column("id", .text).primaryKey()
                t.column("symbol", .text).notNull()
                t.column("content", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "user")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            // Indexes
            try db.create(index: "idx_tracked_stock_symbol",
                          on: "tracked_stock", columns: ["symbol"])
            try db.create(index: "idx_tracked_stock_group",
                          on: "tracked_stock", columns: ["group_id"])
            try db.create(index: "idx_price_history_symbol",
                          on: "price_history", columns: ["symbol"])
            try db.create(index: "idx_holder_symbol",
                          on: "institutional_holder", columns: ["symbol"])
            try db.create(index: "idx_insider_symbol",
                          on: "insider_transaction", columns: ["symbol"])
            try db.create(index: "idx_proxy_symbol",
                          on: "proxy_filing", columns: ["symbol"])
            try db.create(index: "idx_stock_note_symbol",
                          on: "stock_note", columns: ["symbol"])
        }

        return migrator
    }()

    // MARK: - Watchlist Group CRUD

    func createGroup(name: String) throws -> StocksWatchlistGroup {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let group = StocksWatchlistGroup(id: id, name: name, createdAt: now)
        try dbQueue.write { db in try group.insert(db) }
        return group
    }

    func listGroups() throws -> [StocksWatchlistGroup] {
        try dbQueue.read { db in
            try StocksWatchlistGroup.order(Column("created_at").desc).fetchAll(db)
        }
    }

    func deleteGroup(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM watchlist_group WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Tracked Stock CRUD

    func addStock(symbol: String, groupId: String, name: String? = nil, sector: String? = nil, industry: String? = nil) throws -> StocksTrackedStock {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let stock = StocksTrackedStock(
            id: id, groupId: groupId, symbol: symbol.uppercased(),
            name: name, sector: sector, industry: industry,
            notes: nil, isFlagged: false, flagReason: nil,
            addedAt: now, lastChecked: nil)
        try dbQueue.write { db in try stock.insert(db) }
        return stock
    }

    func removeStock(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tracked_stock WHERE id = ?", arguments: [id])
        }
    }

    func listStocks(groupId: String) throws -> [StocksTrackedStock] {
        try dbQueue.read { db in
            try StocksTrackedStock
                .filter(Column("group_id") == groupId)
                .order(Column("added_at").desc)
                .fetchAll(db)
        }
    }

    func allTrackedSymbols() throws -> [String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT symbol FROM tracked_stock")
            return rows.map { $0["symbol"] as String }
        }
    }

    func flagStock(id: String, reason: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracked_stock SET is_flagged = 1, flag_reason = ? WHERE id = ?",
                           arguments: [reason, id])
        }
    }

    func unflagStock(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE tracked_stock SET is_flagged = 0, flag_reason = NULL WHERE id = ?",
                           arguments: [id])
        }
    }

    // MARK: - Price History

    func upsertPriceHistory(symbol: String, entries: [(date: String, open: Double?, high: Double?, low: Double?, close: Double, volume: Double?)]) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            for e in entries {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO price_history (symbol, date, open, high, low, close, volume, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [symbol, e.date, e.open, e.high, e.low, e.close, e.volume, now])
            }
        }
    }

    func priceHistory(symbol: String, limit: Int = 90) throws -> [StocksPriceEntry] {
        try dbQueue.read { db in
            try StocksPriceEntry
                .filter(Column("symbol") == symbol)
                .order(Column("date").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Institutional Holders

    func upsertHolders(symbol: String, holders: [StocksInstitutionalHolder]) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            // Clear old data for this symbol
            try db.execute(sql: "DELETE FROM institutional_holder WHERE symbol = ?", arguments: [symbol])
            for var h in holders {
                h.fetchedAt = now
                try h.insert(db)
            }
        }
    }

    func holders(symbol: String) throws -> [StocksInstitutionalHolder] {
        try dbQueue.read { db in
            try StocksInstitutionalHolder
                .filter(Column("symbol") == symbol)
                .order(Column("percent_held").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Insider Transactions

    func upsertInsiderTransactions(symbol: String, transactions: [StocksInsiderTransaction]) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try dbQueue.write { db in
            for var tx in transactions {
                tx.fetchedAt = now
                try tx.save(db)  // upsert by id
            }
        }
    }

    func insiderTransactions(symbol: String, limit: Int = 50) throws -> [StocksInsiderTransaction] {
        try dbQueue.read { db in
            try StocksInsiderTransaction
                .filter(Column("symbol") == symbol)
                .order(Column("transaction_date").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func insiderTransactionsAll(symbols: [String], limit: Int = 100) throws -> [StocksInsiderTransaction] {
        guard !symbols.isEmpty else { return [] }
        return try dbQueue.read { db in
            try StocksInsiderTransaction
                .filter(symbols.contains(Column("symbol")))
                .order(Column("transaction_date").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Proxy / Voting Filings

    func upsertProxyFiling(_ filing: StocksProxyFiling) throws {
        try dbQueue.write { db in try filing.save(db) }
    }

    func proxyFilings(symbol: String) throws -> [StocksProxyFiling] {
        try dbQueue.read { db in
            try StocksProxyFiling
                .filter(Column("symbol") == symbol)
                .order(Column("filing_date").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Notes

    func addNote(symbol: String, content: String, author: String = "user") throws -> StocksNote {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let note = StocksNote(id: id, symbol: symbol, content: content, author: author,
                              createdAt: now, updatedAt: now)
        try dbQueue.write { db in try note.insert(db) }
        return note
    }

    func notes(symbol: String) throws -> [StocksNote] {
        try dbQueue.read { db in
            try StocksNote
                .filter(Column("symbol") == symbol)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }
}

// MARK: - GRDB Records
//
// CodingKeys are REQUIRED: GRDB maps raw values 1:1 to columns, so every
// camelCase property must declare its snake_case column or writes fail.

struct StocksWatchlistGroup: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "watchlist_group"
    let id: String
    let name: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct StocksTrackedStock: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "tracked_stock"
    let id: String
    let groupId: String
    let symbol: String
    let name: String?
    let sector: String?
    let industry: String?
    let notes: String?
    let isFlagged: Bool
    let flagReason: String?
    let addedAt: String
    let lastChecked: String?

    enum CodingKeys: String, CodingKey {
        case id, symbol, name, sector, industry, notes
        case groupId = "group_id"
        case isFlagged = "is_flagged"
        case flagReason = "flag_reason"
        case addedAt = "added_at"
        case lastChecked = "last_checked"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct StocksPriceEntry: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "price_history"
    let symbol: String
    let date: String
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double
    let volume: Double?
    let fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case symbol, date, open, high, low, close, volume
        case fetchedAt = "fetched_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct StocksInstitutionalHolder: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "institutional_holder"
    let id: String
    let symbol: String
    let holderName: String
    let sharesHeld: Double?
    let percentHeld: Double?
    let dateReported: String?
    let changeShares: Double?
    let changePercent: Double?
    var fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case id, symbol
        case holderName = "holder_name"
        case sharesHeld = "shares_held"
        case percentHeld = "percent_held"
        case dateReported = "date_reported"
        case changeShares = "change_shares"
        case changePercent = "change_percent"
        case fetchedAt = "fetched_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct StocksInsiderTransaction: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "insider_transaction"
    let id: String
    let symbol: String
    let insiderName: String
    let title: String?
    let transactionType: String     // "Buy", "Sell", "Option Exercise"
    let shares: Double?
    let pricePerShare: Double?
    let totalValue: Double?
    let sharesOwned: Double?
    let filingDate: String?
    let transactionDate: String?
    var fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case id, symbol, title, shares
        case insiderName = "insider_name"
        case transactionType = "transaction_type"
        case pricePerShare = "price_per_share"
        case totalValue = "total_value"
        case sharesOwned = "shares_owned"
        case filingDate = "filing_date"
        case transactionDate = "transaction_date"
        case fetchedAt = "fetched_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct StocksProxyFiling: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "proxy_filing"
    let id: String
    let symbol: String
    let companyName: String?
    let filingDate: String
    let accessionNumber: String?
    let url: String?
    let meetingDate: String?
    let proposals: String?           // JSON array
    let voteResults: String?         // JSON: proposal → for/against/abstain
    let executiveCompensation: String?
    let boardMembers: String?        // JSON array
    let fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case id, symbol, url, proposals
        case companyName = "company_name"
        case filingDate = "filing_date"
        case accessionNumber = "accession_number"
        case meetingDate = "meeting_date"
        case voteResults = "vote_results"
        case executiveCompensation = "executive_compensation"
        case boardMembers = "board_members"
        case fetchedAt = "fetched_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}

struct StocksNote: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    static let databaseTableName = "stock_note"
    let id: String
    let symbol: String
    let content: String
    let author: String
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, symbol, content, author
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {}
}
