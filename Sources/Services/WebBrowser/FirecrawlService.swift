import Foundation

/// Native HTTP client for a self-hosted Firecrawl instance (default
/// `http://localhost:3002`). Self-hosted Firecrawl requires no API key.
///
/// Used by the deep-web agent tools as one backend in the fallback chain
/// (alongside static URLSession fetch and the internal WebKit browser). Every
/// method throws on failure so callers can degrade gracefully to another
/// backend instead of failing the whole tool call.
struct FirecrawlService: Sendable {

    let baseURL: URL

    static let shared = FirecrawlService()

    init(baseURL: URL = URL(string: "http://localhost:3002")!) {
        self.baseURL = baseURL
    }

    struct ScrapeResult: Sendable {
        let url: String
        let title: String
        let markdown: String
        let links: [String]
    }

    struct SearchResult: Sendable {
        let title: String
        let url: String
        let snippet: String
    }

    enum FirecrawlError: Error, LocalizedError {
        case badStatus(Int)
        case empty
        case noJobID

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "Firecrawl returned HTTP \(code)"
            case .empty: return "Firecrawl returned no content"
            case .noJobID: return "Firecrawl did not return a crawl job id"
            }
        }
    }

    /// Quick reachability probe with a short timeout. Any HTTP response (even an
    /// error status) counts as "up" — only a connection failure means down.
    func reachable() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }

    /// Reachability with a short-lived cache (default 30s). The deep-web tools
    /// call this before every operation, and an agent run can issue many tool
    /// calls back-to-back; without a cache each one re-probes a possibly-closed
    /// port (connection-refused churn + delay). Within `ttl` the cached verdict
    /// is reused, so a down server is probed once per window instead of per call.
    func reachableCached(ttl: TimeInterval = 30) async -> Bool {
        await ReachabilityCache.shared.reachable(service: self, ttl: ttl)
    }

    // MARK: - Scrape (single page)

    func scrape(url: String, timeout: TimeInterval = 45) async throws -> ScrapeResult {
        let data = try await post("/v1/scrape", body: [
            "url": url,
            "formats": ["markdown", "links"],
        ], timeout: timeout)
        let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataObj = (top?["data"] as? [String: Any]) ?? top
        let metadata = dataObj?["metadata"] as? [String: Any]
        let markdown = (dataObj?["markdown"] as? String) ?? ""
        let title = (metadata?["title"] as? String) ?? (dataObj?["title"] as? String) ?? ""
        let sourceURL = (metadata?["sourceURL"] as? String) ?? url
        let links = (dataObj?["links"] as? [String]) ?? []
        guard !markdown.isEmpty else { throw FirecrawlError.empty }
        return ScrapeResult(url: sourceURL, title: title, markdown: markdown, links: links)
    }

    // MARK: - Search (web search via Firecrawl)

    func search(query: String, limit: Int = 10, timeout: TimeInterval = 20) async throws -> [SearchResult] {
        let data = try await post("/v1/search", body: [
            "query": query,
            "limit": limit,
        ], timeout: timeout)
        let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = (top?["data"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let title = item["title"] as? String,
                  let url = item["url"] as? String else { return nil }
            let snippet = (item["description"] as? String) ?? (item["snippet"] as? String) ?? ""
            return SearchResult(title: title, url: url, snippet: snippet)
        }
    }

    // MARK: - Map (discover URLs)

    func map(url: String, timeout: TimeInterval = 25) async throws -> [String] {
        let data = try await post("/v1/map", body: ["url": url], timeout: timeout)
        let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (top?["links"] as? [String]) ?? []
    }

    // MARK: - Crawl (multi-page)

    /// Start a crawl job and poll until it completes (or the deadline passes),
    /// returning each page's url/title/markdown.
    func crawl(url: String, limit: Int, maxDepth: Int, timeout: TimeInterval = 120) async throws -> [[String: String]] {
        let start = try await post("/v1/crawl", body: [
            "url": url,
            "limit": limit,
            "maxDepth": maxDepth,
            "scrapeOptions": ["formats": ["markdown"]],
        ], timeout: 20)
        guard let top = try JSONSerialization.jsonObject(with: start) as? [String: Any],
              let jobID = (top["id"] as? String) ?? (top["jobId"] as? String) else {
            throw FirecrawlError.noJobID
        }

        let deadline = Date().addingTimeInterval(timeout)
        var collected: [[String: String]] = []
        var seenURLs = Set<String>()
        var nextPath: String? = "/v1/crawl/\(jobID)"

        while let path = nextPath, Date() < deadline {
            var request = URLRequest(url: baseURL.appendingPathComponent(path))
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FirecrawlError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = (obj?["status"] as? String) ?? ""

            for page in (obj?["data"] as? [[String: Any]] ?? []) {
                let meta = page["metadata"] as? [String: Any]
                let markdown = (page["markdown"] as? String) ?? ""
                let pageURL = (meta?["sourceURL"] as? String) ?? (page["url"] as? String) ?? ""
                let title = (meta?["title"] as? String) ?? ""
                guard !markdown.isEmpty, !seenURLs.contains(pageURL) else { continue }
                seenURLs.insert(pageURL)
                collected.append(["url": pageURL, "title": title, "markdown": markdown])
            }

            if status == "completed" || status == "failed" { break }

            // Follow Firecrawl's cursor pagination when present, else re-poll.
            if let next = obj?["next"] as? String, !next.isEmpty,
               let nextURL = URL(string: next), nextURL.host == baseURL.host {
                nextPath = nextURL.path + (nextURL.query.map { "?\($0)" } ?? "")
            } else {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                nextPath = "/v1/crawl/\(jobID)"
            }
        }
        return collected
    }

    // MARK: - HTTP helper

    private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FirecrawlError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}

/// Process-wide cache of the last Firecrawl reachability verdict. Kept outside
/// the struct (which is a value type) so the cache is shared and actor-isolated.
private actor ReachabilityCache {
    static let shared = ReachabilityCache()
    private var lastCheck: (up: Bool, at: Date)?

    func reachable(service: FirecrawlService, ttl: TimeInterval) async -> Bool {
        if let last = lastCheck, Date().timeIntervalSince(last.at) < ttl {
            return last.up
        }
        let up = await service.reachable()
        lastCheck = (up, Date())
        return up
    }
}
