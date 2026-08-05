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
                name: "fetch_url", spec: webToolSpecs[1],
                category: ToolCategory.web.rawValue,
                handler: { call in await fetchURL(call) }),
        ])
    }

    static var webToolSpecs: [ToolSpec] {
        [
            rawSpec("web_search",
                "Search the web using Bing and return results with titles, URLs, and snippets. "
                + "Use this to find current information, documentation, news, or any online content. "
                + "Do NOT call this tool more than 3 times for the same question. If the first "
                + "search does not return useful results, rephrase once, then answer with what you found. "
                + "IMPORTANT: After getting search results, to read full page content use browser_open(url) "
                + "on the most relevant result URL — NOT web_search again. web_search is for DISCOVERING "
                + "URLs; browser_open + browser_read is for READING their content.",
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

    // MARK: - Web Search (Bing HTML)

    private static func webSearch(_ call: ToolCall) async -> String {
        let decodedArgs = decodeArgs(call, as: WebSearchArgs.self)
        let rawQuery = decodedArgs?.query
            ?? call.function.arguments["query"]?.stringValue
        let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let query, !query.isEmpty else {
            return errorJSON("A search query is required.")
        }
        let maxResults = min(max(decodedArgs?.max_results?.value ?? 5, 1), 10)

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://www.bing.com/search?q=\(encoded)") else {
            return errorJSON("Invalid search query.")
        }

        var request = URLRequest(url: searchURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return errorJSON("Search request failed with status \((response as? HTTPURLResponse)?.statusCode ?? -1).")
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            let results = parseBingResults(html, maxResults: maxResults)

            if results.isEmpty {
                return #"{"query": "\#(query)", "results": [], "message": "No results found."}"#
            }

            var output = #"{"query": "\#(query)", "results": ["#
            for (i, result) in results.enumerated() {
                if i > 0 { output += "," }
                output += #"{"title": "\#(jsonEscape(result.title))", "url": "\#(jsonEscape(result.url))", "snippet": "\#(jsonEscape(result.snippet))"}"#
            }
            output += "]}"
            return output
        } catch {
            return errorJSON("Search failed: \(error.localizedDescription)")
        }
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
