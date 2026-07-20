import Foundation
import MLXLMCommon
import SwiftMaestroKit

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
                "Search the web using DuckDuckGo and return results with titles, URLs, and snippets. "
                + "Use this to find current information, documentation, news, or any online content.",
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
        let max_results: FlexibleInt?
    }

    private struct FetchURLArgs: Decodable {
        let url: String?
        let format: String?
    }

    /// Decodes an Int from either a JSON integer or a numeric string.
    private struct FlexibleInt: Decodable {
        let value: Int
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                value = int
                return
            }
            if let string = try? container.decode(String.self), let int = Int(string) {
                value = int
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected Int or numeric String")
        }
    }

    // MARK: - Web Search (DuckDuckGo HTML)

    private static func webSearch(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WebSearchArgs.self),
              let query = args.query, !query.isEmpty else {
            return errorJSON("A search query is required.")
        }
        let maxResults = min(max(args.max_results?.value ?? 5, 1), 10)

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
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
                  httpResponse.statusCode == 200 else {
                return errorJSON("Search request failed with status \((response as? HTTPURLResponse)?.statusCode ?? -1).")
            }
            let html = String(data: data, encoding: .utf8) ?? ""
            let results = parseDDGResults(html, maxResults: maxResults)

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
    private struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    /// Lightweight HTML parser for DuckDuckGo's HTML search results page.
    private static func parseDDGResults(_ html: String, maxResults: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        let lines = html.components(separatedBy: "\n")
        var i = 0

        while i < lines.count && results.count < maxResults {
            let line = lines[i]

            // DuckDuckGo HTML results have: <a class="result__a" href="...">title</a>
            // followed by <a class="result__snippet" ...>snippet</a>
            if line.contains("result__a") {
                let title = extractTagContent(from: line, tag: "a")
                    ?? extractTextBetween(from: line, start: ">", end: "</a>")
                    ?? ""
                let url = extractHref(from: line) ?? ""

                // Look ahead for snippet
                var snippet = ""
                for j in (i + 1)..<min(i + 10, lines.count) {
                    if lines[j].contains("result__snippet") {
                        snippet = extractTagContent(from: lines[j], tag: "a")
                            ?? extractTextBetween(from: lines[j], start: ">", end: "</a>")
                            ?? ""
                        break
                    }
                }

                if !title.isEmpty && !url.isEmpty {
                    results.append(SearchResult(
                        title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                        snippet: snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }
            i += 1
        }
        return results
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
    private static func htmlToMarkdown(_ html: String) -> String {
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
