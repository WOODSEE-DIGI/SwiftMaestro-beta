import Foundation
import MLXLMCommon
import SwiftMaestroKit

private extension JSONValue {
    /// Convenience for reading a string argument without round-tripping
    /// through JSONDecoder. Useful as a fallback when small-model output
    /// doesn't decode cleanly into the expected Codable shape.
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

// MARK: - Native Web Search & Fetch Tools
//
// Built-in web tools using URLSession — no MCP server, no external dependencies.
// These give every SwiftMaestro install instant web access on first launch.
// MCP-sourced web tools (webclaw, firecrawl, etc.) provide deeper capabilities
// when the user enables them in Settings → MCP.

extension MaestroTools {

    /// Registers native web tools with `ToolRegistry`.
    static func registerWebTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "web_search", spec: webToolSpecs[0],
                category: ToolCategory.web.rawValue,
                handler: { call in await webSearch(call) }),
            ToolDefinition(
                name: "search_businesses", spec: webToolSpecs[2],
                category: ToolCategory.web.rawValue,
                handler: { call in await searchBusinesses(call) }),
            ToolDefinition(
                name: "google_maps_search", spec: webToolSpecs[3],
                category: ToolCategory.web.rawValue,
                handler: { call in await googleMapsSearch(call) }),
            ToolDefinition(
                name: "fetch_url", spec: webToolSpecs[1],
                category: ToolCategory.web.rawValue,
                handler: { call in await fetchURL(call) }),
        ])
    }

    static var webToolSpecs: [ToolSpec] {
        [
            rawSpec("web_search",
                "Search the web AND read the top results. Returns titles, URLs, snippets, "
                + "AND full page content (up to 3000 chars each). "
                + "Use this for ALL web research — you do NOT need to call browser_open or "
                + "browser_read after web_search; the content is already included. "
                + "QUERY RULES: "
                + "- Keep queries SHORT (3-8 words). Bad: 'air conditioning installation services "
                + "Sydney NSW contact phone number reviews'. Good: 'HVAC installer Sydney'. "
                + "- Do NOT include noise words: 'contact', 'phone', 'reviews', 'services', "
                + "'company', 'top rated' — they degrade quality. "
                + "- Include location if relevant: 'plumber Melbourne CBD'. "
                + "- MAX 2 searches total. After 2, STOP and use what you got. "
                + "If results are poor, say so honestly instead of making things up.",
                properties: [
                    "query": ["type": "string", "description": "Search query string"],
                    "max_results": ["type": "integer", "description": "Max results to return (default 5, max 10)"],
                ],
                required: ["query"]),
            rawSpec("fetch_url",
                "Fetch a URL and return its content as clean markdown. Use for reading articles, "
                + "documentation, or any web page content. Supports HTML pages.",
                properties: [
                    "url": ["type": "string", "description": "URL to fetch (must start with http:// or https://)"],
                    "format": ["type": "string", "description": "Output format: 'markdown' (default) or 'text'"],
                ],
                required: ["url"]),
            rawSpec("search_businesses",
                "ONE-SHOT local business search. Searches the web for businesses near a location, "
                + "opens the results in the in-app Maps panel, and returns structured results with "
                + "name, address, phone, and website. Use this INSTEAD of calling web_search + "
                + "search_maps_panel separately — it does both in one call. "
                + "The model should present the results directly from the tool output.",
                properties: [
                    "query": ["type": "string", "description": "Search query, e.g. 'HVAC installer Sydney' or 'café Melbourne CBD'"],
                    "location": ["type": "string", "description": "Location context for the search, e.g. 'Sydney 2010'"],
                    "max_results": ["type": "integer", "description": "Max results (default 3, max 5)"],
                ],
                required: ["query"]),
            rawSpec("google_maps_search",
                "Search Google Maps for local businesses. Returns real business data with names, "
                + "addresses, phone numbers, websites, and ratings from Google Maps — the best "
                + "source for local business information. Use this for ANY local business search "
                + "(restaurants, services, shops, professionals). Opens the Maps panel automatically.",
                properties: [
                    "query": ["type": "string", "description": "What to search for, e.g. 'HVAC installer' or 'pizza restaurant'"],
                    "location": ["type": "string", "description": "Location, e.g. 'Sydney 2010' or 'Melbourne CBD'"],
                    "max_results": ["type": "integer", "description": "Max results (default 5, max 10)"],
                ],
                required: ["query"]),
        ]
    }

    // MARK: - Args

    private struct WebSearchArgs: Decodable {
        let query: String?
        let max_results: LenientInt?
    }

    private struct FetchURLArgs: Decodable {
        let url: String?
        let format: String?
    }

    private struct SearchBusinessesArgs: Decodable {
        let query: String?
        let location: String?
        let max_results: LenientInt?
    }

    private struct GoogleMapsSearchArgs: Decodable {
        let query: String?
        let location: String?
        let max_results: LenientInt?
    }

    // MARK: - Web Search (Firecrawl first, Bing HTML fallback)

    private static func webSearch(_ call: ToolCall) async -> String {
        let decodedArgs = decodeArgs(call, as: WebSearchArgs.self)
        let rawQuery = decodedArgs?.query
            ?? call.function.arguments["query"]?.stringValue
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query, !query.isEmpty else {
            return errorJSON("A search query is required.")
        }
        let maxResults = min(max(decodedArgs?.max_results?.value ?? 5, 1), 10)

        // --- Stage 1: Firecrawl search API (primary — clean structured results) ---
        var results: [SearchResult] = []
        let firecrawl = FirecrawlService.shared
        if await firecrawl.reachableCached() {
            if let fcResults = try? await firecrawl.search(query: query, limit: maxResults) {
                results = fcResults.map { SearchResult(title: $0.title, url: $0.url, snippet: $0.snippet) }
            }
        }

        // --- Stage 2: Bing HTML fallback (when Firecrawl is down or returns nothing) ---
        if results.isEmpty {
            var bingBlocked = false
            if let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "https://www.bing.com/search?q=\(encoded)") {
                var request = URLRequest(url: searchURL)
                request.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                    forHTTPHeaderField: "User-Agent"
                )
                request.timeoutInterval = 15

                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) {
                    let html = String(data: data, encoding: .utf8) ?? ""
                    let lower = html.lowercased()
                    if lower.contains("captcha") || lower.contains("are you a robot")
                        || lower.contains("unusual traffic") || lower.contains("verify you are human") {
                        bingBlocked = true
                    } else {
                        results = parseBingResults(html, maxResults: maxResults)
                    }
                }
            }

            if results.isEmpty && bingBlocked {
                return #"{"query": "\#(query)", "results": [], "message": "Search was blocked by CAPTCHA. Try rephrasing the query or using browser_open on a specific site."}"#
            }
        }

        if results.isEmpty {
            return #"{"query": "\#(query)", "results": [], "message": "No results found."}"#
        }

        // --- Stage 3: Auto-fetch full page content for top results ---
        // The model often stops at snippets and fabricates details. Fetching full
        // page content gives it real data (phone numbers, addresses, prices) so it
        // doesn't need to call browser_open/browser_read separately.
        let fetchLimit = min(results.count, 3)
        var enrichedResults: [String] = []
        await withTaskGroup(of: (Int, String?).self) { group in
            for i in 0..<fetchLimit {
                let url = results[i].url
                group.addTask { await (i, fetchPageContent(url: url)) }
            }
            var fetched = [Int: String]()
            for await (idx, content) in group {
                fetched[idx] = content
            }
            for i in 0..<results.count {
                let r = results[i]
                var entry = #"{"title": "\#(jsonEscape(r.title))", "url": "\#(jsonEscape(r.url))", "snippet": \#(jsonEscape(r.snippet))"#
                if i < fetchLimit, let content = fetched[i], !content.isEmpty {
                    entry += #", "content": "\#(jsonEscape(content))""#
                }
                enrichedResults.append(entry + "}")
            }
        }

        var output = #"{"query": "\#(query)", "results": ["#
        output += enrichedResults.joined(separator: ",")
        output += "]}"
        return output
    }

    /// Fetch a URL and extract readable text content (lightweight — no JS, just HTML text extraction).
    /// Returns truncated content (max ~3000 chars) to keep tool results manageable.
    private static func fetchPageContent(url: String) async -> String? {
        guard let fetchURL = URL(string: url) else { return nil }
        var request = URLRequest(url: fetchURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            return nil
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        // Quick HTML-to-text: strip tags, collapse whitespace
        let text = html
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&[a-zA-Z]+;", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncate to keep tool result manageable
        if text.count > 3000 {
            return String(text.prefix(3000)) + "..."
        }
        return text.isEmpty ? nil : text
    }

    // MARK: - One-shot Business Search

    /// Searches for businesses via web search, returns structured results with
    /// name/address/phone/website, and opens the Maps panel.
    private static func searchBusinesses(_ call: ToolCall) async -> String {
        let decodedArgs = decodeArgs(call, as: SearchBusinessesArgs.self)
        let rawQuery = decodedArgs?.query
            ?? call.function.arguments["query"]?.stringValue
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query, !query.isEmpty else {
            return errorJSON("search_businesses requires 'query'")
        }
        let location = decodedArgs?.location?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxResults = min(max(decodedArgs?.max_results?.value ?? 3, 1), 5)

        // Build search query — keep it SHORT for better results
        let searchQuery = [query, location].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")

        // 1. Web search (Firecrawl first, Bing fallback)
        var results: [SearchResult] = []
        let firecrawl = FirecrawlService.shared
        if await firecrawl.reachableCached() {
            if let fcResults = try? await firecrawl.search(query: searchQuery, limit: maxResults + 2) {
                results = fcResults.map { SearchResult(title: $0.title, url: $0.url, snippet: $0.snippet) }
            }
        }
        if results.isEmpty {
            if let encoded = searchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "https://www.bing.com/search?q=\(encoded)") {
                var request = URLRequest(url: searchURL)
                request.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                    forHTTPHeaderField: "User-Agent"
                )
                request.timeoutInterval = 15
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) {
                    let html = String(data: data, encoding: .utf8) ?? ""
                    if !html.lowercased().contains("captcha") {
                        results = parseBingResults(html, maxResults: maxResults + 2)
                    }
                }
            }
        }

        // 2. Auto-fetch full page content for each result (parallel)
        var enrichedResults: [[String: Any]] = []
        let fetchLimit = min(results.count, maxResults + 2)
        let resultURLs = results.map(\.url)
        
        await withTaskGroup(of: (Int, String?).self) { group in
            for i in 0..<fetchLimit {
                let url = resultURLs[i]
                group.addTask { await (i, fetchPageContent(url: url)) }
            }
            for await (idx, content) in group {
                let r = results[idx]
                var entry: [String: Any] = [
                    "title": r.title,
                    "url": r.url,
                    "snippet": r.snippet,
                ]
                if let content, !content.isEmpty {
                    entry["content"] = content
                }
                enrichedResults.append(entry)
            }
        }

        guard !enrichedResults.isEmpty else {
            return #"{"query": "\#(jsonEscape(searchQuery))", "results": [], "message": "No results found."}"#
        }

        // 3. Open Maps panel with the search query
        await MainActor.run {
            WorkspaceLayoutState.shared.open(.maps)
            NotificationCenter.default.post(
                name: .openWorkspacePanel,
                object: WorkspacePanelKind.maps
            )
            AppleMapsService.shared.panelSearchQuery = searchQuery
            AppleMapsService.shared.panelSearchMode = "Places"
            AppleMapsService.shared.panelSearchTrigger = UUID()
        }

        // 4. Return results as JSON
        let resultsData = try? JSONSerialization.data(withJSONObject: enrichedResults)
        let resultsString = resultsData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return #"{"query": "\#(jsonEscape(searchQuery))", "count": \#(enrichedResults.count), "results": \#(resultsString)}"#
    }

    // MARK: - Google Maps Business Search

    /// Searches Google Maps for local businesses via Firecrawl, returns structured
    /// results with name/address/phone/website/rating, and opens the Maps panel.
    private static func googleMapsSearch(_ call: ToolCall) async -> String {
        let decodedArgs = decodeArgs(call, as: GoogleMapsSearchArgs.self)
        let rawQuery = decodedArgs?.query
            ?? call.function.arguments["query"]?.stringValue
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query, !query.isEmpty else {
            return errorJSON("google_maps_search requires 'query'")
        }
        let location = decodedArgs?.location?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxResults = min(max(decodedArgs?.max_results?.value ?? 5, 1), 10)

        // Build Google Maps-specific search query
        let mapQuery = [query, location].compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " ")

        // Try Google Maps URL via Firecrawl scrape first
        var businesses: [[String: Any]] = []

        let firecrawl = FirecrawlService.shared
        if await firecrawl.reachableCached() {
            // Encode for Google Maps search URL
            if let encoded = mapQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let mapsURL = URL(string: "https://www.google.com/maps/search/\(encoded)") {
                if let result = try? await firecrawl.scrape(url: mapsURL.absoluteString),
                   !result.markdown.isEmpty {
                    // Parse Google Maps business listings from markdown
                    businesses = parseGoogleMapsResults(result.markdown, maxResults: maxResults)
                }
            }

            // Fallback: Firecrawl web search for "site:google.com/maps" + query
            if businesses.isEmpty {
                if let fcResults = try? await firecrawl.search(query: "\(mapQuery) site:google.com/maps", limit: maxResults + 3) {
                    for fc in fcResults where !fc.title.isEmpty {
                        businesses.append([
                            "name": fc.title,
                            "url": fc.url,
                            "snippet": fc.snippet,
                        ])
                    }
                }
            }

            // Final fallback: general web search for the business query
            if businesses.isEmpty {
                if let fcResults = try? await firecrawl.search(query: mapQuery, limit: maxResults + 3) {
                    for fc in fcResults where !fc.title.isEmpty {
                        businesses.append([
                            "name": fc.title,
                            "url": fc.url,
                            "snippet": fc.snippet,
                        ])
                    }
                }
            }
        }

        // Bing fallback if Firecrawl is down
        if businesses.isEmpty {
            if let encoded = mapQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "https://www.bing.com/search?q=\(encoded)+google+maps") {
                var request = URLRequest(url: searchURL)
                request.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                    forHTTPHeaderField: "User-Agent"
                )
                request.timeoutInterval = 15
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) {
                    let html = String(data: data, encoding: .utf8) ?? ""
                    let bingResults = parseBingResults(html, maxResults: maxResults + 3)
                    for br in bingResults {
                        businesses.append([
                            "name": br.title,
                            "url": br.url,
                            "snippet": br.snippet,
                        ])
                    }
                }
            }
        }

        guard !businesses.isEmpty else {
            return #"{"query": "\#(jsonEscape(mapQuery))", "results": [], "message": "No Google Maps results found."}"#
        }

        // 2. Open Maps panel with the search query
        await MainActor.run {
            WorkspaceLayoutState.shared.open(.maps)
            NotificationCenter.default.post(
                name: .openWorkspacePanel,
                object: WorkspacePanelKind.maps
            )
            AppleMapsService.shared.panelSearchQuery = mapQuery
            AppleMapsService.shared.panelSearchMode = "Places"
            AppleMapsService.shared.panelSearchTrigger = UUID()
        }

        // 3. Return results as JSON
        let limited = Array(businesses.prefix(maxResults))
        let resultsData = try? JSONSerialization.data(withJSONObject: limited)
        let resultsString = resultsData.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return #"{"query": "\#(jsonEscape(mapQuery))", "count": \#(limited.count), "results": \#(resultsString)}"#
    }

    /// Parse Google Maps markdown output into structured business data.
    private static func parseGoogleMapsResults(_ markdown: String, maxResults: Int) -> [[String: Any]] {
        var results: [[String: Any]] = []
        let lines = markdown.components(separatedBy: "\n")

        var currentName: String?
        var currentAddress: String?
        var currentPhone: String?
        var currentWebsite: String?
        var currentRating: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.starts(with: "#") || trimmed.starts(with: "!") { continue }

            // Rating pattern: "4.5 (123)" or "4.5/5"
            if let ratingMatch = trimmed.range(of: #"(\d+\.?\d*)\s*[\(/]"#, options: .regularExpression) {
                currentRating = String(trimmed[ratingMatch]).replacingOccurrences(of: "(", with: "").replacingOccurrences(of: "/", with: " ")
                continue
            }

            // Phone pattern: contains digits with formatting
            if trimmed.range(of: #"[\d\-\(\)\+\s]{7,}"#, options: .regularExpression) != nil
               && trimmed.range(of: #"[a-zA-Z]"#, options: .regularExpression) == nil {
                currentPhone = trimmed
                continue
            }

            // Website pattern
            if trimmed.lowercased().contains("http") || trimmed.lowercased().contains("www.") {
                currentWebsite = trimmed
                continue
            }

            // Address-like: contains street/suburb/road/etc.
            if trimmed.range(of: #"(street|road|avenue|lane|drive|place|court|sq|blvd|st\b|rd\b|ln\b|dr\b|ct\b|pl\b|ave\b| Way\b|close\b)"#, options: .regularExpression) != nil {
                currentAddress = trimmed
                continue
            }

            // If we have a previous business, save it
            if let name = currentName {
                var entry: [String: Any] = ["name": name]
                if let addr = currentAddress { entry["address"] = addr }
                if let phone = currentPhone { entry["phone"] = phone }
                if let website = currentWebsite { entry["website"] = website }
                if let rating = currentRating { entry["rating"] = rating }
                results.append(entry)
                if results.count >= maxResults { break }
            }

            // This line is likely the business name (non-empty, doesn't match other patterns)
            currentName = trimmed
            currentAddress = nil
            currentPhone = nil
            currentWebsite = nil
            currentRating = nil
        }

        // Don't forget the last entry
        if results.count < maxResults, let name = currentName {
            var entry: [String: Any] = ["name": name]
            if let addr = currentAddress { entry["address"] = addr }
            if let phone = currentPhone { entry["phone"] = phone }
            if let website = currentWebsite { entry["website"] = website }
            if let rating = currentRating { entry["rating"] = rating }
            results.append(entry)
        }

        return results
    }

    /// Parsed search result.
    internal struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    /// Lightweight HTML parser for Bing's web search results page.
    /// Bing wraps the real target URL in a `/ck/a?...u=<base64>` redirect; we
    /// decode the `u` parameter so the model receives the actual article URL.
    internal static func parseBingResults(_ html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        let marker = "<li class=\"b_algo\""
        for block in html.components(separatedBy: marker).dropFirst() {
            guard results.count < maxResults else { break }

            // Truncate at the matching </li> so nested results don't bleed through.
            let end = block.range(of: "</li>")?.lowerBound ?? block.endIndex
            let body = String(block[..<end])

            let title = extractBingTitle(body)
            let snippet = extractBingSnippet(body)
            guard let redirect = extractBingRedirect(body) else { continue }
            let url = decodeBingURL(redirect) ?? redirect

            guard !title.isEmpty, !url.isEmpty else { continue }
            results.append(SearchResult(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return results
    }

    private static func extractBingTitle(_ block: String) -> String {
        let pattern = #"<h2[^>]*>.*?<a[^>]*href=\"[^\"]*\"[^>]*>(.*?)</a>.*?</h2>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: block, options: [], range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block) else { return "" }
        return stripHtmlTags(String(block[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractBingRedirect(_ block: String) -> String? {
        let pattern = #"<h2[^>]*>.*?<a[^>]*href=\"([^\"]+)\"[^>]*>.*?</a>.*?</h2>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: block, options: [], range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block) else { return nil }
        return String(block[range])
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractBingSnippet(_ block: String) -> String {
        let pattern = #"<p class=\"b_lineclamp2\"[^>]*>(.*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: block, options: [], range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block) else { return "" }
        return stripHtmlTags(String(block[range])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode Bing's `u` parameter back to the target URL.
    /// The value is standard base64 prefixed with a 2-char algorithm marker (e.g. "a1").
    private static func decodeBingURL(_ redirect: String) -> String? {
        guard let uRange = redirect.range(of: "[?&]u=", options: .regularExpression) else { return nil }
        var encoded = String(redirect[uRange.upperBound...])
        if let amp = encoded.firstIndex(of: "&") {
            encoded = String(encoded[..<amp])
        }
        encoded = encoded.removingPercentEncoding ?? encoded
        if encoded.hasPrefix("a1") || encoded.hasPrefix("a2") {
            encoded.removeFirst(2)
        }
        let padding = encoded.count % 4
        if padding > 0, padding < 4 {
            encoded.append(contentsOf: String(repeating: "=", count: 4 - padding))
        }
        guard let data = Data(base64Encoded: encoded, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func stripHtmlTags(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    // MARK: - Fetch URL

    private static func fetchURL(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: FetchURLArgs.self),
              let urlString = args.url, !urlString.isEmpty else {
            return errorJSON("A URL is required.")
        }

        guard let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return errorJSON("Invalid URL. Must start with http:// or https://.")
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return errorJSON("Request failed with status \((response as? HTTPURLResponse)?.statusCode ?? -1).")
            }

            let html = String(data: data, encoding: .utf8) ?? ""
            let contentType = httpResponse.mimeType ?? ""

            if contentType.contains("text/html") {
                let markdown = htmlToMarkdown(html)
                let output: [String: any Sendable] = [
                    "url": urlString,
                    "content_type": contentType,
                    "markdown": markdown,
                    "length": markdown.count,
                ]
                return encodeJSON(output)
            } else {
                // Non-HTML content — return metadata
                let output: [String: any Sendable] = [
                    "url": urlString,
                    "content_type": contentType,
                    "size_bytes": data.count,
                    "note": "Non-HTML content. Use read_file for local files.",
                ]
                return encodeJSON(output)
            }
        } catch {
            return errorJSON("Fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - HTML → Markdown Conversion

    /// Converts HTML to approximate markdown. Handles common tags: headings,
    /// paragraphs, links, bold, italic, code, lists, and images. Strips scripts
    /// and styles. Not a full parser — good enough for readable content extraction.
    /// Internal (not private) so the deep-web tools can reuse it for static fetch.
    static func htmlToMarkdown(_ html: String) -> String {
        var text = html

        // Remove script and style blocks entirely
        text = removeTagPattern(text, tag: "script")
        text = removeTagPattern(text, tag: "style")
        text = removeTagPattern(text, tag: "noscript")

        // Convert block-level tags to newlines
        for tag in ["p", "div", "section", "article", "blockquote", "li", "tr", "br", "hr"] {
            text = text.replacingOccurrences(
                of: "</\(tag)[^>]*>",
                with: "\n",
                options: .regularExpression
            )
        }

        // Headings
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level)
            text = text.replacingOccurrences(
                of: "<h\(level)[^>]*>(.*?)</h\(level)>",
                with: "\n\(prefix) $1\n",
                options: .regularExpression
            )
        }

        // Bold
        text = text.replacingOccurrences(
            of: "<(?:b|strong)[^>]*>(.*?)</(?:b|strong)>",
            with: "**$1**",
            options: .regularExpression
        )

        // Italic
        text = text.replacingOccurrences(
            of: "<(?:i|em)[^>]*>(.*?)</(?:i|em)>",
            with: "*$1*",
            options: .regularExpression
        )

        // Inline code
        text = text.replacingOccurrences(
            of: "<code[^>]*>(.*?)</code>",
            with: "`$1`",
            options: .regularExpression
        )

        // Links
        text = text.replacingOccurrences(
            of: "<a[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>",
            with: "[$2]($1)",
            options: .regularExpression
        )

        // Images → alt text
        text = text.replacingOccurrences(
            of: "<img[^>]*alt=\"([^\"]*?)\"[^>]*>",
            with: "[$1]",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<img[^>]*>",
            with: "",
            options: .regularExpression
        )

        // Lists
        text = text.replacingOccurrences(
            of: "<li[^>]*>",
            with: "\n- ",
            options: .regularExpression
        )

        // Strip remaining HTML tags
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&rdquo;", "\""), ("&ldquo;", "\""),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Collapse multiple newlines
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove an entire `<tag>...</tag>` block (including contents).
    private static func removeTagPattern(_ text: String, tag: String) -> String {
        text.replacingOccurrences(
            of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
            with: "",
            options: .regularExpression
        )
    }

    /// Extract text content from inside an HTML tag.
    private static func extractTagContent(from html: String, tag: String) -> String? {
        guard let range = html.range(
            of: "<\(tag)[^>]*>([\\s\\S]*?)</\(tag)>",
            options: .regularExpression
        ) else { return nil }
        let match = String(html[range])
        return extractTextBetween(from: match, start: ">", end: "</\(tag)>")
    }

    /// Extract text between two delimiters.
    private static func extractTextBetween(from text: String, start: String, end: String) -> String? {
        guard let startIdx = text.range(of: start, options: .backwards)?.upperBound,
              let endIdx = text.range(of: end, options: .backwards, range: startIdx..<text.endIndex)?.lowerBound,
              startIdx < endIdx else { return nil }
        return String(text[startIdx..<endIdx])
    }

    /// Extract href URL from an HTML tag.
    private static func extractHref(from html: String) -> String? {
        guard let range = html.range(
            of: "href=\"([^\"]+)\"",
            options: .regularExpression
        ) else { return nil }
        let href = String(html[range])
        return extractTextBetween(from: href, start: "href=\"", end: "\"")
    }

    // MARK: - JSON Helpers

    private static func jsonEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func encodeJSON(_ dict: [String: any Sendable]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
