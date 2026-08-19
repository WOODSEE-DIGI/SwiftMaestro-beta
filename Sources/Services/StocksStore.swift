import Foundation

// MARK: - Stocks store
//
// Watchlist + live quotes for the Stocks panel and the agent's stocks tools.
// Quote data comes from stooq.com's free CSV endpoints — no API key, no
// account, nothing for the user to configure. Refresh is gentle: on panel
// appear, on explicit refresh, and on a 60 s timer while the panel is open.

/// One symbol the user watches. `id` is the stooq symbol.
struct StockWatchItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { symbol }
    /// Stooq-normalized symbol (lowercase, exchange suffix, e.g. "aapl.us").
    let symbol: String
    /// What the user typed, uppercased (e.g. "AAPL").
    let displaySymbol: String
}

/// A parsed quote row from stooq's `f=sd2t2ohlcv` CSV format.
struct StockQuote: Equatable, Sendable {
    let symbol: String
    let date: String
    let time: String
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double?
    let volume: Double?

    /// Intraday move from the open (stooq's quote row has no previous close).
    var changePercent: Double? {
        guard let open, let close, open > 0 else { return nil }
        return (close - open) / open * 100
    }
}

@Observable
@MainActor
final class StocksStore {
    static let shared = StocksStore()

    private(set) var watchlist: [StockWatchItem] = []
    private(set) var quotes: [String: StockQuote] = [:]
    /// Trailing daily closes per stooq symbol (oldest → newest), for sparklines.
    private(set) var histories: [String: [Double]] = [:]
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    var lastError: String?

    private let session = URLSession.shared
    private static let historyDays = 90

    private init() { load() }

    // MARK: - Persistence

    private var watchlistURL: URL {
        SwiftMaestroPaths.appSupportDir.appendingPathComponent("stocks-watchlist.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: watchlistURL),
              let items = try? JSONDecoder().decode([StockWatchItem].self, from: data) else { return }
        watchlist = items
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(watchlist) else { return }
        try? data.write(to: watchlistURL, options: .atomic)
    }

    // MARK: - Symbol normalization

    /// "AAPL" → "aapl.us"; "aapl.us" / "bhp.au" / "^spx" pass through (lowercased).
    static func normalizeSymbol(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("^") { return trimmed.lowercased() }
        if trimmed.contains(".") { return trimmed.lowercased() }
        guard trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return trimmed.lowercased() + ".us"
    }

    // MARK: - Watchlist

    @discardableResult
    func add(symbol raw: String) -> StockWatchItem? {
        guard let normalized = Self.normalizeSymbol(raw) else { return nil }
        if let existing = watchlist.first(where: { $0.symbol == normalized }) { return existing }
        let item = StockWatchItem(symbol: normalized, displaySymbol: raw.uppercased())
        watchlist.append(item)
        save()
        Task { await refreshQuotes() }
        Task { await refreshHistory(for: normalized) }
        return item
    }

    func remove(symbol raw: String) {
        guard let normalized = Self.normalizeSymbol(raw) else { return }
        watchlist.removeAll { $0.symbol == normalized }
        quotes.removeValue(forKey: normalized)
        histories.removeValue(forKey: normalized)
        save()
    }

    // MARK: - Fetching

    /// One batched quote request for the whole watchlist (stooq accepts
    /// comma-separated symbols in a single call).
    func refreshQuotes() async {
        let symbols = watchlist.map(\.symbol)
        guard !symbols.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await fetchQuotes(symbols: symbols)
            for quote in fetched { quotes[quote.symbol] = quote }
            lastRefresh = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Quote for ANY symbol (agent use — not necessarily on the watchlist).
    func quote(for raw: String) async -> StockQuote? {
        guard let normalized = Self.normalizeSymbol(raw) else { return nil }
        return try? await fetchQuotes(symbols: [normalized]).first
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

    // MARK: - Stooq CSV

    private func fetchQuotes(symbols: [String]) async throws -> [StockQuote] {
        let joined = symbols.joined(separator: ",")
        guard let url = URL(string: "https://stooq.com/q/l/?s=\(joined)&f=sd2t2ohlcv&h&e=csv") else {
            return []
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parseQuoteCSV(text)
    }

    private func parseQuoteCSV(_ text: String) -> [StockQuote] {
        var rows: [StockQuote] = []
        for line in text.split(separator: "\n").dropFirst() {  // drop header
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .init(charactersIn: "\"\r ")) }
            guard cols.count >= 8 else { continue }
            func num(_ i: Int) -> Double? {
                let raw = cols[i]
                return raw == "N/D" || raw.isEmpty ? nil : Double(raw)
            }
            rows.append(StockQuote(
                symbol: cols[0], date: cols[1], time: cols[2],
                open: num(3), high: num(4), low: num(5), close: num(6), volume: num(7)))
        }
        return rows
    }

    /// Daily closes for the trailing `historyDays` days (stooq's daily CSV).
    private func fetchHistoryCloses(symbol: String) async throws -> [Double] {
        guard let url = URL(string: "https://stooq.com/q/d/l/?s=\(symbol)&i=d") else { return [] }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let closes = text.split(separator: "\n").dropFirst().compactMap { line -> Double? in
            let cols = line.split(separator: ",")
            guard cols.count >= 5 else { return nil }
            return Double(cols[4])
        }
        return Array(closes.suffix(Self.historyDays))
    }
}
