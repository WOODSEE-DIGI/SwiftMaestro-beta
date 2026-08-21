import Foundation

// MARK: - SEC EDGAR Service
//
// Free, no-key API for US public company filings.
// Uses EDGAR's submissions API + full-text search.
// Rate-limited: 10 requests/sec max (EDGAR policy).
// User-Agent must identify the caller (SEC requirement).

enum StocksEDGARService {

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static let userAgent = "SwiftMaestro/1.0 (github.com/woodsee/SwiftMaestro; contact@swiftmaestro.app)"

    // MARK: - Ticker -> CIK resolution

    private static nonisolated(unsafe) var tickerMapCache: [String: (cik: String, title: String)] = [:]
    private static nonisolated(unsafe) var tickerMapLoaded = false

    static func cik(forTicker ticker: String) async throws -> (cik: String, title: String)? {
        if !tickerMapLoaded { try await loadTickerMap() }
        return tickerMapCache[ticker.uppercased()]
    }

    private static func loadTickerMap() async throws {
        guard let url = URL(string: "https://www.sec.gov/files/company_tickers.json") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (_, value) in json {
            guard let obj = value as? [String: Any],
                  let cik = obj["cik_str"] as? Int,
                  let ticker = obj["ticker"] as? String,
                  let title = obj["title"] as? String else { continue }
            tickerMapCache[ticker.uppercased()] = (String(format: "%010d", cik), title)
        }
        tickerMapLoaded = true
    }

    // MARK: - Company Submissions

    struct CompanySubmissions: Sendable {
        let name: String
        let ticker: String
        let cik: String
        let recentFilings: [FilingSummary]
    }

    struct FilingSummary: Sendable, Identifiable {
        var id: String { accessionNumber }
        let form: String
        let filingDate: String
        let accessionNumber: String
        let primaryDocument: String
        let description: String?
    }

    static func recentFilings(ticker: String, formType: String? = nil) async throws -> CompanySubmissions {
        guard let (cik, title) = try await cik(forTicker: ticker) else {
            throw StocksEDGARError.tickerNotFound(ticker)
        }
        let url = URL(string: "https://data.sec.gov/submissions/CIK\(cik).json")!
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filings = json["filings"] as? [String: Any],
              let recent = filings["recent"] as? [String: Any] else {
            throw StocksEDGARError.invalidResponse
        }
        let forms = recent["form"] as? [String] ?? []
        let dates = recent["filingDate"] as? [String] ?? []
        let accessions = recent["accessionNumber"] as? [String] ?? []
        let docs = recent["primaryDocument"] as? [String] ?? []
        let descs = recent["primaryDocDescription"] as? [String] ?? []

        var summaries: [FilingSummary] = []
        for i in 0..<min(forms.count, min(dates.count, accessions.count)) {
            let form = forms[i]
            if let formType, !form.localizedCaseInsensitiveContains(formType) { continue }
            summaries.append(FilingSummary(
                form: form, filingDate: dates[i], accessionNumber: accessions[i],
                primaryDocument: docs[safe: i] ?? "",
                description: descs[safe: i]))
        }
        return CompanySubmissions(name: title, ticker: ticker.uppercased(), cik: cik, recentFilings: summaries)
    }

    // MARK: - Proxy Filing Data

    struct ProxyFilingData: Sendable {
        let companyName: String
        let ticker: String
        let filingDate: String
        let accessionNumber: String
        let url: String
        let meetingDate: String?
        let proposals: [Proposal]
        let boardMembers: [String]
        let executiveCompensation: String?

        struct Proposal: Sendable, Identifiable {
            var id: String { "\(number)-\(title)" }
            let number: Int
            let title: String
            let description: String?
        }
    }

    static func fetchProxyFiling(accessionNumber: String, primaryDocument: String, ticker: String) async throws -> ProxyFilingData {
        let resolvedCik: String
        let companyName: String
        if let info = try await Self.cik(forTicker: ticker) {
            resolvedCik = info.cik
            companyName = info.title
        } else {
            throw StocksEDGARError.tickerNotFound(ticker)
        }
        let cleanAccession = accessionNumber.replacingOccurrences(of: "-", with: "")
        let indexURL = "https://www.sec.gov/Archives/edgar/data/\(resolvedCik)/\(cleanAccession)/\(primaryDocument)"
        var req = URLRequest(url: URL(string: indexURL)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: req)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw StocksEDGARError.invalidResponse
        }
        return ProxyFilingData(
            companyName: companyName, ticker: ticker.uppercased(),
            filingDate: "", accessionNumber: accessionNumber,
            url: indexURL, meetingDate: parseMeetingDate(from: html),
            proposals: parseProposals(from: html),
            boardMembers: parseBoardMembers(from: html),
            executiveCompensation: parseExecutiveCompensation(from: html))
    }

    // MARK: - Insider Transactions (Form 4)

    struct InsiderTransactionEntry: Sendable {
        let insiderName: String
        let title: String?
        let transactionType: String
        let shares: Double?
        let pricePerShare: Double?
        let totalValue: Double?
        let sharesOwned: Double?
        let filingDate: String
        let transactionDate: String?
        let accessionNumber: String
    }

    static func insiderTransactions(ticker: String, limit: Int = 30) async throws -> [InsiderTransactionEntry] {
        guard let (cik, _) = try await cik(forTicker: ticker) else {
            throw StocksEDGARError.tickerNotFound(ticker)
        }
        let submissions = try await recentFilings(ticker: ticker, formType: "4")
        var entries: [InsiderTransactionEntry] = []
        for filing in submissions.recentFilings.prefix(limit) {
            do {
                let cleanAcc = filing.accessionNumber.replacingOccurrences(of: "-", with: "")
                let docURL = "https://www.sec.gov/Archives/edgar/data/\(cik)/\(cleanAcc)/\(filing.primaryDocument)"
                var req = URLRequest(url: URL(string: docURL)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                let (data, _) = try await session.data(for: req)
                guard let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else { continue }
                entries.append(contentsOf: parseForm4(xml, accessionNumber: filing.accessionNumber, filingDate: filing.filingDate))
            } catch {
                continue
            }
        }
        return entries
    }
}

// MARK: - Errors

enum StocksEDGARError: LocalizedError {
    case tickerNotFound(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .tickerNotFound(let t): return "Ticker '\(t)' not found on SEC EDGAR"
        case .invalidResponse: return "Invalid response from SEC EDGAR"
        }
    }
}
