import Foundation

// MARK: - Stocks store
//
// Watchlist + live quotes for the Stocks panel and the agent's stocks tools.
// Quote data comes from Yahoo Finance's chart API — no API key, no account,
// nothing for the user to configure. Refresh is gentle: on panel appear, on
// explicit refresh, and on a 60 s timer while the panel is open.

/// One symbol the user watches. `id` is the Yahoo Finance symbol.
struct StockWatchItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { symbol }
    /// Yahoo Finance symbol (uppercase, exchange suffix, e.g. "BHP.AX").
    let symbol: String
    /// What the user typed, uppercased (e.g. "AAPL").
    let displaySymbol: String
}

/// A parsed quote from Yahoo Finance's chart API.
struct StockQuote: Equatable, Sendable {
    let symbol: String
    let price: Double
    let previousClose: Double
    let dayHigh: Double?
    let dayLow: Double?
    let volume: Double?

    var changePercent: Double? {
        guard previousClose > 0 else { return nil }
        return (price - previousClose) / previousClose * 100
    }
}

/// A market mover entry from Yahoo Finance's screener API.
struct StockMover: Identifiable, Sendable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let price: Double
    let changePercent: Double
    let volume: Double?
}

@Observable
@MainActor
final class StocksStore {
    static let shared = StocksStore()

    private(set) var watchlist: [StockWatchItem] = []
    private(set) var quotes: [String: StockQuote] = [:]
    private(set) var histories: [String: [Double]] = [:]
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    var lastError: String?

    // Discover tab state
    private(set) var topGainers: [StockMover] = []
    private(set) var topLosers: [StockMover] = []
    private(set) var mostActive: [StockMover] = []
    private(set) var isDiscoverLoading = false
    var discoverError: String?

    // MARK: - Investigation State (DB-backed)

    let db: StocksDatabase
    private(set) var groups: [StocksWatchlistGroup] = []
    private(set) var currentGroup: StocksWatchlistGroup?
    private(set) var trackedStocks: [StocksTrackedStock] = []
    private(set) var holdersCache: [String: [StocksInstitutionalHolder]] = [:]
    private(set) var insiderCache: [String: [StocksInsiderTransaction]] = [:]
    private(set) var proxyCache: [String: [StocksProxyFiling]] = [:]
    private(set) var notesCache: [String: [StocksNote]] = [:]
    private(set) var isLoadingHolders = false
    private(set) var isLoadingInsider = false
    private(set) var isLoadingProxy = false

    private let session = URLSession.shared
    private static let historyDays = 90

    private init() {
        db = StocksDatabase.shared
        loadGroups()
        loadLegacyWatchlist()
    }

    // MARK: - Legacy Persistence (JSON file → DB migration)

    private var watchlistURL: URL {
        SwiftMaestroPaths.appSupportDir.appendingPathComponent("stocks-watchlist.json")
    }

    /// Migrate legacy JSON watchlist into DB groups on first launch.
    private func loadGroups() {
        do {
            groups = try db.listGroups()
            if let first = groups.first {
                currentGroup = first
                trackedStocks = try db.listStocks(groupId: first.id)
            }
        } catch {
            lastError = "Failed to load groups: \(error.localizedDescription)"
        }
    }

    private func loadLegacyWatchlist() {
        guard let data = try? Data(contentsOf: watchlistURL),
              let items = try? JSONDecoder().decode([StockWatchItem].self, from: data),
              !items.isEmpty else { return }
        // Migrate: create a default group and add all legacy symbols
        if groups.isEmpty {
            do {
                let group = try db.createGroup(name: "My Watchlist")
                groups.append(group)
                currentGroup = group
                for item in items {
                    if let normalized = Self.normalizeSymbol(item.displaySymbol) {
                        _ = try? db.addStock(symbol: normalized, groupId: group.id)
                    }
                }
                trackedStocks = try db.listStocks(groupId: group.id)
            } catch {
                lastError = "Migration failed: \(error.localizedDescription)"
            }
        }
        // Load into legacy watchlist for backwards compat
        var migrated = false
        var updated: [StockWatchItem] = []
        for item in items {
            if let normalized = Self.normalizeSymbol(item.displaySymbol) {
                if normalized != item.symbol { migrated = true }
                updated.append(StockWatchItem(symbol: normalized, displaySymbol: item.displaySymbol))
            }
        }
        if migrated {
            watchlist = updated
            saveJSON()
        } else {
            watchlist = items
        }
    }

    private func saveJSON() {
        guard let data = try? JSONEncoder().encode(watchlist) else { return }
        try? data.write(to: watchlistURL, options: .atomic)
    }

    // MARK: - Symbol normalization

    /// "AAPL" → "AAPL" (US, no suffix needed); "bhp.au" → "BHP.AX";
    /// "BHP" → "BHP"; "^spx" → "^GSPC"; "msft" → "MSFT";
    /// "600519.SH" → "600519.SS"; "000858.SZ" → "000858.SZ".
    static func normalizeSymbol(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        // Index tickers: map common names to Yahoo symbols.
        if upper == "^SPX" || upper == "^SPY" || upper == "^S&P500" || upper == "^S&P 500" {
            return "^GSPC"
        }
        if upper.hasPrefix("^") { return upper }
        // Australian: "BHP.AU" or "BHP" + user says AU → "BHP.AX"
        if upper.hasSuffix(".AU") {
            return String(upper.dropLast(3)) + ".AX"
        }
        // Shanghai: "600519.SH" → "600519.SS" (Yahoo uses .SS, not .SH)
        if upper.hasSuffix(".SH") {
            return String(upper.dropLast(3)) + ".SS"
        }
        // Shenzhen / Hong Kong / other exchanges — pass through as-is.
        if upper.contains(".") { return upper }
        // Plain ticker — assume US (no suffix needed for Yahoo).
        guard upper.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return upper
    }

    // MARK: - Watchlist

    @discardableResult
    func add(symbol raw: String) -> StockWatchItem? {
        guard let normalized = Self.normalizeSymbol(raw) else { return nil }
        if let existing = watchlist.first(where: { $0.symbol == normalized }) { return existing }
        let item = StockWatchItem(symbol: normalized, displaySymbol: raw.uppercased())
        watchlist.append(item)
        saveJSON()
        // Also add to current DB group
        if let groupId = currentGroup?.id {
            _ = try? db.addStock(symbol: normalized, groupId: groupId)
            trackedStocks = (try? db.listStocks(groupId: groupId)) ?? []
        }
        Task { await refreshQuotes() }
        Task { await refreshHistory(for: normalized) }
        return item
    }

    func remove(symbol raw: String) {
        let before = watchlist.count
        watchlist.removeAll { $0.symbol == raw || $0.displaySymbol.uppercased() == raw.uppercased() }
        guard watchlist.count < before else { return }
        if let normalized = Self.normalizeSymbol(raw) {
            quotes.removeValue(forKey: normalized)
            histories.removeValue(forKey: normalized)
            // Remove from DB
            if let stock = trackedStocks.first(where: { $0.symbol == normalized }) {
                try? db.removeStock(id: stock.id)
            }
        }
        quotes.removeValue(forKey: raw)
        histories.removeValue(forKey: raw)
        saveJSON()
        if let groupId = currentGroup?.id {
            trackedStocks = (try? db.listStocks(groupId: groupId)) ?? []
        }
    }

    // MARK: - Fetching (Watchlist)

    /// Fetch quotes for the whole watchlist via Yahoo Finance chart API.
    func refreshQuotes() async {
        let symbols = watchlist.map(\.symbol)
        guard !symbols.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            for symbol in symbols {
                if let quote = try await fetchQuote(symbol: symbol) {
                    quotes[symbol] = quote
                }
            }
            lastRefresh = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Quote for ANY symbol (agent use — not necessarily on the watchlist).
    func quote(for raw: String) async -> StockQuote? {
        guard let normalized = Self.normalizeSymbol(raw) else { return nil }
        return try? await fetchQuote(symbol: normalized)
    }

    func refreshHistory(for symbol: String? = nil) async {
        let targets = symbol.map { [$0] } ?? watchlist.map(\.symbol)
        await withTaskGroup(of: (String, [Double]?).self) { group in
            for target in targets {
                group.addTask { (target, try? await self.fetchHistoryCloses(symbol: target)) }
            }
            for await (target, closes) in group {
                if let closes, !closes.isEmpty { histories[target] = closes }
            }
        }
    }

    /// Fetch trailing closes for any symbol (used by featured landing page).
    func historyCloses(for symbol: String) async -> [Double] {
        (try? await fetchHistoryCloses(symbol: symbol)) ?? []
    }

    // MARK: - Fetching (Discover / Market Movers)

    func refreshDiscover() async {
        isDiscoverLoading = true
        discoverError = nil
        async let gainers = fetchScreener(scrId: "day_gainers", count: 10)
        async let losers = fetchScreener(scrId: "day_losers", count: 10)
        async let active = fetchScreener(scrId: "most_actives", count: 10)
        let (g, l, a) = await (gainers, losers, active)
        topGainers = g
        topLosers = l
        mostActive = a
        isDiscoverLoading = false
    }

    // MARK: - Yahoo Finance

    private func fetchQuote(symbol: String) async throws -> StockQuote? {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=1d") else {
            return nil
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("SwiftMaestro/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let first = results.first,
              let meta = first["meta"] as? [String: Any],
              let price = meta["regularMarketPrice"] as? Double,
              let prevClose = meta["chartPreviousClose"] as? Double
        else { return nil }

        // Extract intraday high/low from the indicators.
        var dayHigh: Double?
        var dayLow: Double?
        var volume: Double?
        if let indicators = first["indicators"] as? [String: Any],
           let quote = indicators["quote"] as? [[String: Any]],
           let firstQuote = quote.first {
            if let highs = firstQuote["high"] as? [Double] {
                dayHigh = highs.compactMap({ $0 > 0 ? $0 : nil }).max()
            }
            if let lows = firstQuote["low"] as? [Double] {
                dayLow = lows.compactMap({ $0 > 0 ? $0 : nil }).min()
            }
            if let vols = firstQuote["volume"] as? [Double] {
                volume = vols.reduce(0, +)
            }
        }

        return StockQuote(
            symbol: symbol, price: price, previousClose: prevClose,
            dayHigh: dayHigh, dayLow: dayLow, volume: volume)
    }

    private func fetchHistoryCloses(symbol: String) async throws -> [Double] {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=\(Self.historyDays)d") else {
            return []
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("SwiftMaestro/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let first = results.first,
              let indicators = first["indicators"] as? [String: Any],
              let quote = indicators["quote"] as? [[String: Any]],
              let firstQuote = quote.first,
              let closes = firstQuote["close"] as? [Double]
        else { return [] }
        return closes.compactMap { $0 > 0 ? $0 : nil }
    }

    /// Yahoo Finance screener: day_gainers, day_losers, most_actives.
    private func fetchScreener(scrId: String, count: Int) async -> [StockMover] {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/screener/predefined/saved?scrIds=\(scrId)&count=\(count)") else {
            return []
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("SwiftMaestro/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let finance = json["finance"] as? [String: Any],
              let results = finance["result"] as? [[String: Any]],
              let first = results.first,
              let quotes = first["quotes"] as? [[String: Any]]
        else { return [] }

        return quotes.compactMap { q in
            guard let symbol = q["symbol"] as? String,
                  let price = q["regularMarketPrice"] as? Double else { return nil }
            let name = (q["shortName"] as? String) ?? symbol
            let change = q["regularMarketChangePercent"] as? Double ?? 0
            let volume = q["regularMarketVolume"] as? Double
            return StockMover(symbol: symbol, name: name, price: price, changePercent: change, volume: volume)
        }
    }

    // MARK: - Yahoo Finance Holders API

    /// Fetch institutional holders for a ticker (top 10 from Yahoo Finance).
    func fetchHolders(symbol: String) async {
        isLoadingHolders = true
        defer { isLoadingHolders = false }
        guard let normalized = Self.normalizeSymbol(symbol) else { return }
        do {
            let url = URL(string: "https://query2.finance.yahoo.com/v10/finance/quoteSummary/\(normalized)?modules=institutionalOwnership")!
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.setValue("SwiftMaestro/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: req)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["quoteSummary"] as? [String: Any],
                  let results = result["result"] as? [[String: Any]],
                  let first = results.first,
                  let ownership = first["institutionalOwnership"] as? [String: Any],
                  let holders = ownership["holders"] as? [[String: Any]] else { return }

            let parsed: [StocksInstitutionalHolder] = holders.enumerated().compactMap { idx, h in
                guard let name = h["organization"] as? String else { return nil }
                let pct = h["pctHeld"] as? [String: Any]
                let pctVal = pct?["raw"] as? Double
                let shares = h["position"] as? [String: Any]
                let sharesVal = shares?["raw"] as? Double
                let reportDate = h["reportDate"] as? [String: Any]
                let dateStr = reportDate?["fmt"] as? String
                let chgShares = h["positionDirect"] as? [String: Any]
                let chgVal = chgShares?["raw"] as? Double
                return StocksInstitutionalHolder(
                    id: "\(normalized)-holder-\(idx)",
                    symbol: normalized, holderName: name,
                    sharesHeld: sharesVal, percentHeld: pctVal,
                    dateReported: dateStr, changeShares: chgVal,
                    changePercent: nil, fetchedAt: "")
            }
            try db.upsertHolders(symbol: normalized, holders: parsed)
            holdersCache[normalized] = parsed
        } catch {
            lastError = "Holders fetch failed: \(error.localizedDescription)"
        }
    }

    /// Load cached holders from DB.
    func loadHolders(symbol: String) {
        guard let normalized = Self.normalizeSymbol(symbol) else { return }
        holdersCache[normalized] = (try? db.holders(symbol: normalized)) ?? []
    }

    // MARK: - Insider Transactions (EDGAR)

    func fetchInsiderTransactions(symbol: String) async {
        isLoadingInsider = true
        defer { isLoadingInsider = false }
        guard let normalized = Self.normalizeSymbol(symbol) else { return }
        do {
            let entries = try await StocksEDGARService.insiderTransactions(ticker: normalized, limit: 30)
            let records: [StocksInsiderTransaction] = entries.map { e in
                StocksInsiderTransaction(
                    id: "\(normalized)-insider-\(e.accessionNumber)-\(e.insiderName)",
                    symbol: normalized, insiderName: e.insiderName,
                    title: e.title, transactionType: e.transactionType,
                    shares: e.shares, pricePerShare: e.pricePerShare,
                    totalValue: e.totalValue, sharesOwned: e.sharesOwned,
                    filingDate: e.filingDate, transactionDate: e.transactionDate,
                    fetchedAt: "")
            }
            try db.upsertInsiderTransactions(symbol: normalized, transactions: records)
            insiderCache[normalized] = (try? db.insiderTransactions(symbol: normalized)) ?? []
        } catch {
            lastError = "Insider fetch failed: \(error.localizedDescription)"
        }
    }

    func loadInsiderTransactions(symbol: String) {
        guard let normalized = Self.normalizeSymbol(symbol) else { return }
        insiderCache[normalized] = (try? db.insiderTransactions(symbol: normalized)) ?? []
    }

    // MARK: - Proxy / Voting Filings (EDGAR)

    func fetchProxyFilings(symbol: String) async {
        isLoadingProxy = true
        defer { isLoadingProxy = false }
        guard let normalized = Self.normalizeSymbol(symbol) else { return }
        do {
            let subs = try await StocksEDGARService.recentFilings(ticker: normalized, formType: "DEF 14A")
            for filing in subs.recentFilings.prefix(5) {
                let proxyData = try await StocksEDGARService.fetchProxyFiling(
                    accessionNumber: filing.accessionNumber,
                    primaryDocument: filing.primaryDocument,
                    ticker: normalized)
                let proposalDicts: [[String: Any]] = proxyData.proposals.map { p in
                    ["number": p.number, "title": p.title, "description": p.description ?? ""]
                }
                let proposalsJSON = try? JSONSerialization.data(withJSONObject: proposalDicts)
                let boardJSON = try? JSONSerialization.data(withJSONObject: proxyData.boardMembers)
                let record = StocksProxyFiling(
                    id: "\(normalized)-proxy-\(filing.accessionNumber)",
                    symbol: normalized, companyName: proxyData.companyName,
                    filingDate: filing.filingDate, accessionNumber: filing.accessionNumber,
                    url: proxyData.url, meetingDate: proxyData.meetingDate,
                    proposals: proposalsJSON.flatMap { String(data: $0, encoding: .utf8) },
                    voteResults: nil,
                    executiveCompensation: proxyData.executiveCompensation,
                    boardMembers: boardJSON.flatMap { String(data: $0, encoding: .utf8) },
                    fetchedAt: "")
                try db.upsertProxyFiling(record)
            }
            proxyCache[normalized] = (try? db.proxyFilings(symbol: normalized)) ?? []
        } catch {
            lastError = "Proxy fetch failed: \(error.localizedDescription)"
        }
    }

    func loadProxyFilings(symbol: String) {
        guard let normalized = Self.normalizeSymbol(symbol) else { return }
        proxyCache[normalized] = (try? db.proxyFilings(symbol: normalized)) ?? []
    }

    // MARK: - Notes

    func addNote(symbol: String, content: String) -> StocksNote? {
        guard let normalized = Self.normalizeSymbol(symbol) else { return nil }
        guard let note = try? db.addNote(symbol: normalized, content: content) else { return nil }
        notesCache[normalized, default: []].insert(note, at: 0)
        return note
    }

    func loadNotes(symbol: String) {
        guard let normalized = Self.normalizeSymbol(symbol) else { return }
        notesCache[normalized] = (try? db.notes(symbol: normalized)) ?? []
    }

    // MARK: - Group Management

    func createGroup(name: String) {
        guard let group = try? db.createGroup(name: name) else { return }
        groups.insert(group, at: 0)
        selectGroup(group)
    }

    func selectGroup(_ group: StocksWatchlistGroup) {
        currentGroup = group
        trackedStocks = (try? db.listStocks(groupId: group.id)) ?? []
    }

    func deleteGroup(_ group: StocksWatchlistGroup) {
        try? db.deleteGroup(id: group.id)
        groups.removeAll { $0.id == group.id }
        if currentGroup?.id == group.id {
            currentGroup = groups.first
            if let gid = currentGroup?.id {
                trackedStocks = (try? db.listStocks(groupId: gid)) ?? []
            } else {
                trackedStocks = []
            }
        }
    }

    // MARK: - Flagging

    func flagStock(id: String, reason: String) {
        try? db.flagStock(id: id, reason: reason)
        if let gid = currentGroup?.id {
            trackedStocks = (try? db.listStocks(groupId: gid)) ?? []
        }
    }

    func unflagStock(id: String) {
        try? db.unflagStock(id: id)
        if let gid = currentGroup?.id {
            trackedStocks = (try? db.listStocks(groupId: gid)) ?? []
        }
    }

    // MARK: - Price History Persistence

    func persistPriceHistory(symbol: String) async {
        guard let normalized = Self.normalizeSymbol(symbol),
              let closes = histories[normalized], !closes.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = Date()
        var entries: [(date: String, open: Double?, high: Double?, low: Double?, close: Double, volume: Double?)] = []
        for (i, close) in closes.enumerated() {
            guard let date = Calendar.current.date(byAdding: .day, value: -(closes.count - 1 - i), to: today) else { continue }
            entries.append((date: formatter.string(from: date), open: nil, high: nil, low: nil, close: close, volume: nil))
        }
        try? db.upsertPriceHistory(symbol: normalized, entries: entries)
    }
}
