import Foundation
import MLXLMCommon
import SwiftMaestroKit
import zlib

// MARK: - Deep-Web Crawl & Read Tools
//
// Orchestrates multiple scraping backends so no single one is a point of
// failure — the exact problem the user hits when one of Playwright / Firecrawl /
// WebClaw can't handle a given site. The chain per tool:
//
//   deep_fetch : static URLSession -> Firecrawl scrape -> internal WebKit browser
//   web_crawl  : Firecrawl /crawl  -> internal-browser breadth-first crawl
//   site_map   : Firecrawl /map    -> sitemap.xml / robots.txt parsing
//
// Firecrawl is optional (self-hosted at http://localhost:3002). When it's down,
// the internal browser (always available, renders JS) is the fallback, so the
// tools keep working. WebClaw / Playwright remain available as MCP servers for
// the hardest interactive / anti-bot cases.

extension MaestroTools {

    static func registerDeepWebTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "deep_fetch", spec: deepWebToolSpecs[0],
                category: ToolCategory.web.rawValue,
                handler: { call in await deepFetch(call) }),
            ToolDefinition(
                name: "web_crawl", spec: deepWebToolSpecs[1],
                category: ToolCategory.web.rawValue,
                handler: { call in await webCrawl(call) }),
            ToolDefinition(
                name: "site_map", spec: deepWebToolSpecs[2],
                category: ToolCategory.web.rawValue,
                handler: { call in await siteMap(call) }),
        ])
    }

    static var deepWebToolSpecs: [ToolSpec] {
        [
            rawSpec("deep_fetch",
                "Read a single web page deeply, trying multiple backends until one returns real "
                + "content. Use when fetch_url returns a blocked/JS-required/thin page. backend 'auto' "
                + "(default) tries static fetch, then Firecrawl (if running), then the rendered internal "
                + "browser. Returns the winning backend and the page content as markdown (or text/html).",
                properties: [
                    "url": ["type": "string", "description": "Page URL to read"],
                    "backend": ["type": "string", "description": "auto (default), static, firecrawl, or browser"],
                    "format": ["type": "string", "description": "markdown (default), text, or html"],
                ],
                required: ["url"]),
            rawSpec("web_crawl",
                "Crawl a whole site and return many pages' content. Use for research across an entire "
                + "site or docs section. Uses Firecrawl /crawl when it's running, otherwise a "
                + "rendered internal-browser breadth-first crawl over same-domain links. Returns a list "
                + "of {url, title, markdown} (each truncated).",
                properties: [
                    "url": ["type": "string", "description": "Root URL to start crawling from"],
                    "limit": ["type": "integer", "description": "Max pages to return (default 8, max 40)"],
                    "max_depth": ["type": "integer", "description": "Link-follow depth (default 1, max 4)"],
                    "backend": ["type": "string", "description": "auto (default), firecrawl, or browser"],
                ],
                required: ["url"]),
            rawSpec("site_map",
                "Discover the URLs on a site so you can choose which pages to read or crawl. Uses "
                + "Firecrawl /map when running, otherwise parses sitemap.xml and robots.txt. Returns a "
                + "list of URLs.",
                properties: [
                    "url": ["type": "string", "description": "Site root URL"],
                    "limit": ["type": "integer", "description": "Max URLs to return (default 200, max 1000)"],
                    "backend": ["type": "string", "description": "auto (default), firecrawl, or sitemap"],
                ],
                required: ["url"]),
        ]
    }

    // MARK: - Args

    private struct DeepFetchArgs: Decodable { let url: String?; let backend: String?; let format: String? }
    private struct CrawlArgs: Decodable { let url: String?; let limit: LenientInt?; let max_depth: LenientInt?; let backend: String? }
    private struct MapArgs: Decodable { let url: String?; let limit: LenientInt?; let backend: String? }

    // MARK: - deep_fetch

    @MainActor
    private static func deepFetch(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: DeepFetchArgs.self)
        guard let urlString = args?.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else { return errorJSON("'url' is required") }
        let backend = (args?.backend ?? "auto").lowercased()
        let format = (args?.format ?? "markdown").lowercased()

        switch backend {
        case "static":
            if let r = await staticFetchMarkdown(urlString) {
                return jsonString(["url": urlString, "backend": "static", "content_type": r.contentType,
                                   "markdown": r.markdown, "length": r.markdown.count])
            }
            return errorJSON("Static fetch failed for \(urlString)")
        case "firecrawl":
            return await firecrawlFetch(urlString)
        case "browser":
            return await browserFetchPage(urlString, format: format)
        default:
            break // auto chain below
        }

        // auto: static -> firecrawl -> internal browser
        if let r = await staticFetchMarkdown(urlString),
           r.markdown.count >= 400, !looksBlocked(r.markdown) {
            return jsonString(["url": urlString, "backend": "static",
                               "markdown": r.markdown, "length": r.markdown.count])
        }
        if await FirecrawlService.shared.reachableCached(),
           let result = try? await FirecrawlService.shared.scrape(url: urlString),
           result.markdown.count >= 200 {
            return jsonString(["url": result.url, "backend": "firecrawl", "title": result.title,
                               "markdown": result.markdown, "length": result.markdown.count])
        }
        return await browserFetchPage(urlString, format: format)
    }

    private static func firecrawlFetch(_ urlString: String) async -> String {
        guard await FirecrawlService.shared.reachableCached() else {
            return errorJSON("Firecrawl is not reachable at \(FirecrawlService.shared.baseURL.absoluteString). "
                + "Start it (Docker) or use backend=browser or backend=static.")
        }
        do {
            let result = try await FirecrawlService.shared.scrape(url: urlString)
            return jsonString(["url": result.url, "backend": "firecrawl", "title": result.title,
                               "markdown": result.markdown, "length": result.markdown.count])
        } catch {
            return errorJSON("Firecrawl scrape failed: \(error.localizedDescription)")
        }
    }

    /// Open the page in a background internal-browser tab, wait for render, then
    /// extract markdown (Web Clipper) or plain text. Always available.
    @MainActor
    private static func browserFetchPage(_ urlString: String, format: String) async -> String {
        let store = WebBrowserStore.shared
        guard let tab = store.openURLInNewTab(urlString, background: true) else {
            return errorJSON("Invalid URL: \(urlString)")
        }
        await tab.waitUntilLoaded(timeout: 20)
        defer { store.closeTab(id: tab.id) }
        // A failed load (mangled/unresolvable URL, DNS) is a real failure — report it
        // as an error, not empty content, so the caller AND the failure-circuit-breaker
        // see it and the model stops retrying instead of looping on a dead URL.
        if let loadError = tab.error, !loadError.isEmpty {
            return errorJSON("deep_fetch could not load the page: \(loadError)")
        }
        let url = tab.currentURL?.absoluteString ?? urlString

        if format == "text" {
            let text = await tabInnerText(tab)
            return jsonString(["url": url, "backend": "browser", "title": tab.title,
                               "text": text, "length": text.count])
        }
        if let html = try? await tab.capturePageHTML(), !html.isEmpty,
           let result = try? await WebClipperService.shared.clip(html: html, url: url) {
            return jsonString(["url": url, "backend": "browser", "title": result.title,
                               "markdown": result.markdown, "length": result.markdown.count])
        }
        let text = await tabInnerText(tab)
        return jsonString(["url": url, "backend": "browser", "title": tab.title,
                           "text": text, "length": text.count, "note": "fell back to plain text"])
    }

    // MARK: - web_crawl

    @MainActor
    private static func webCrawl(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: CrawlArgs.self)
        guard let urlString = args?.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else { return errorJSON("'url' is required") }
        let limit = min(max(args?.limit?.value ?? 8, 1), 40)
        let maxDepth = min(max(args?.max_depth?.value ?? 1, 0), 4)
        let backend = (args?.backend ?? "auto").lowercased()

        let firecrawlUp = await FirecrawlService.shared.reachableCached()
        let useFirecrawl = backend == "firecrawl" || (backend == "auto" && firecrawlUp)
        if useFirecrawl {
            do {
                let pages = try await FirecrawlService.shared.crawl(url: urlString, limit: limit, maxDepth: maxDepth)
                if !pages.isEmpty {
                    let trimmed = pages.map { [
                        "url": $0["url"] ?? "", "title": $0["title"] ?? "",
                        "markdown": truncate($0["markdown"] ?? "", 4000),
                    ] }
                    return jsonString(["url": urlString, "backend": "firecrawl",
                                       "count": trimmed.count, "pages": trimmed])
                }
            } catch {
                if backend == "firecrawl" {
                    return errorJSON("Firecrawl crawl failed: \(error.localizedDescription)")
                }
            }
        }

        let pages = await browserBreadthFirstCrawl(urlString: urlString, limit: limit, maxDepth: maxDepth)
        return jsonString(["url": urlString, "backend": "browser", "count": pages.count, "pages": pages])
    }

    /// Rendered breadth-first crawl over same-domain links using the internal
    /// browser. Opens each page in a background tab, extracts links + markdown.
    @MainActor
    private static func browserBreadthFirstCrawl(urlString: String, limit: Int, maxDepth: Int) async -> [[String: Any]] {
        let store = WebBrowserStore.shared
        guard let root = normalizedHTTPURL(urlString) else { return [] }
        let rootHost = root.host?.lowercased() ?? ""

        var visited = Set<String>()
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var pages: [[String: Any]] = []

        while !queue.isEmpty, pages.count < limit {
            let (url, depth) = queue.removeFirst()
            let key = normalizeForVisit(url)
            if visited.contains(key) { continue }
            visited.insert(key)

            guard let tab = store.openURLInNewTab(key, background: true) else { continue }
            await tab.waitUntilLoaded(timeout: 15)

            var childLinks: [String] = []
            if let data = try? await tab.evaluateJavaScript("Array.from(document.querySelectorAll('a[href]')).map(a => a.href)"),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                childLinks = arr
            }

            var markdown = ""
            var title = tab.title
            if let html = try? await tab.capturePageHTML(), !html.isEmpty,
               let result = try? await WebClipperService.shared.clip(html: html, url: key) {
                markdown = result.markdown
                if !result.title.isEmpty { title = result.title }
            } else {
                markdown = await tabInnerText(tab)
            }
            store.closeTab(id: tab.id)

            pages.append(["url": key, "title": title, "markdown": truncate(markdown, 4000)])

            guard depth < maxDepth else { continue }
            for link in childLinks {
                guard let child = URL(string: link),
                      let scheme = child.scheme?.lowercased(), ["http", "https"].contains(scheme),
                      child.host?.lowercased() == rootHost else { continue }
                let childKey = normalizeForVisit(child)
                if !visited.contains(childKey) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return pages
    }

    // MARK: - site_map

    private static func siteMap(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: MapArgs.self)
        guard let urlString = args?.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else { return errorJSON("'url' is required") }
        let limit = min(max(args?.limit?.value ?? 200, 1), 1000)
        let backend = (args?.backend ?? "auto").lowercased()

        let firecrawlUp = await FirecrawlService.shared.reachableCached()
        let useFirecrawl = backend == "firecrawl" || (backend == "auto" && firecrawlUp)
        if useFirecrawl {
            if let links = try? await FirecrawlService.shared.map(url: urlString), !links.isEmpty {
                return jsonString(["url": urlString, "backend": "firecrawl",
                                   "count": min(links.count, limit), "links": Array(links.prefix(limit))])
            }
            if backend == "firecrawl" {
                return errorJSON("Firecrawl map returned no links for \(urlString)")
            }
        }

        let links = await sitemapURLs(for: urlString, limit: limit)
        if !links.isEmpty {
            return jsonString(["url": urlString, "backend": "sitemap", "count": links.count, "links": links])
        }
        // The site publishes no reachable sitemap (common on JS / anti-bot sites
        // that deliberately omit one — e.g. Stack Overflow's robots.txt is a bare
        // `Disallow: /`). Fall back to harvesting same-domain links from the
        // rendered root page in the internal browser, which bypasses JS/anti-bot.
        let harvested = await browserHarvestLinks(urlString: urlString, limit: limit)
        return jsonString(["url": urlString,
                           "backend": harvested.isEmpty ? "sitemap" : "browser",
                           "count": harvested.count, "links": harvested])
    }

    /// Render the root page in a background internal-browser tab and collect
    /// deduplicated same-domain link hrefs as a lightweight site map. Used when
    /// the site exposes no reachable sitemap (JS/anti-bot sites).
    @MainActor
    private static func browserHarvestLinks(urlString: String, limit: Int) async -> [String] {
        let store = WebBrowserStore.shared
        guard let root = normalizedHTTPURL(urlString),
              let tab = store.openURLInNewTab(root.absoluteString, background: true) else { return [] }
        await tab.waitUntilLoaded(timeout: 20)
        defer { store.closeTab(id: tab.id) }
        let rootHost = root.host?.lowercased() ?? ""
        guard let data = try? await tab.evaluateJavaScript(
                "Array.from(document.querySelectorAll('a[href]')).map(a => a.href)"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for link in arr {
            guard let u = URL(string: link),
                  let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  u.host?.lowercased() == rootHost else { continue }
            let key = normalizeForVisit(u)
            if seen.insert(key).inserted {
                out.append(key)
                if out.count >= limit { break }
            }
        }
        return out
    }

    /// Parse robots.txt `Sitemap:` directives plus the conventional
    /// /sitemap.xml and /sitemap_index.xml, extracting <loc> URLs (following
    /// sitemap indexes one level). Non-isolated: pure URLSession work.
    private static func sitemapURLs(for urlString: String, limit: Int) async -> [String] {
        guard let base = normalizedHTTPURL(urlString),
              let scheme = base.scheme, let host = base.host else { return [] }
        let origin = "\(scheme)://\(host)"

        var candidates = ["\(origin)/sitemap.xml", "\(origin)/sitemap_index.xml"]
        if let robots = await fetchText("\(origin)/robots.txt") {
            for line in robots.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.lowercased().hasPrefix("sitemap:") {
                    let loc = trimmed.dropFirst("sitemap:".count).trimmingCharacters(in: .whitespaces)
                    if !loc.isEmpty { candidates.append(loc) }
                }
            }
        }

        var pageURLs: [String] = []
        var toProcess = candidates
        var processed = 0
        // Follow sitemap indexes (which may nest, and whose children are often
        // .xml.gz) until we have enough page URLs, bounding total fetches.
        while !toProcess.isEmpty, pageURLs.count < limit, processed < 25 {
            let sitemapURL = toProcess.removeFirst()
            processed += 1
            guard let xml = await fetchText(sitemapURL) else { continue }
            if isSitemapIndex(xml) {
                toProcess.append(contentsOf: extractAllLocs(from: xml))
            } else {
                pageURLs.append(contentsOf: extractAllLocs(from: xml))
            }
        }

        var seen = Set<String>()
        return pageURLs.filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }

    /// A sitemap index wraps child <sitemap> entries; a urlset wraps page <url>
    /// entries. Detecting the root element is far more robust than guessing from
    /// the filename (children are frequently `.xml.gz` or oddly named).
    private static func isSitemapIndex(_ xml: String) -> Bool {
        xml.contains("<sitemapindex")
    }

    /// All <loc> entries regardless of type — the caller distinguishes index vs
    /// urlset via `isSitemapIndex`.
    private static func extractAllLocs(from xml: String) -> [String] {
        var out: [String] = []
        for part in xml.components(separatedBy: "<loc>").dropFirst() {
            guard let end = part.range(of: "</loc>") else { continue }
            let loc = String(part[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !loc.isEmpty { out.append(loc) }
        }
        return out
    }

    // MARK: - Shared helpers

    /// Fast static fetch → markdown. Returns nil on any failure. Non-isolated.
    private static func staticFetchMarkdown(_ urlString: String) async -> (markdown: String, contentType: String)? {
        guard let url = normalizedHTTPURL(urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        let contentType = http.mimeType ?? ""
        let raw = String(data: data, encoding: .utf8) ?? ""
        if contentType.contains("text/html") {
            return (htmlToMarkdown(raw), contentType)
        }
        return (raw, contentType)
    }

    /// Heuristic: does this look like a JS-required / anti-bot / block page?
    private static func looksBlocked(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "enable javascript", "please enable cookies", "captcha", "cf-chl",
            "cloudflare", "access denied", "are you a robot", "verify you are human",
            "attention required", "just a moment",
        ]
        return markers.contains { lower.contains($0) }
    }

    @MainActor
    private static func tabInnerText(_ tab: BrowserTab) async -> String {
        guard let data = try? await tab.evaluateJavaScript("document.body ? document.body.innerText : ''") else { return "" }
        return (try? JSONDecoder().decode(String.self, from: data)) ?? ""
    }

    private static func normalizedHTTPURL(_ string: String) -> URL? {
        // Run model URLs through the same cleaner browser_open uses, so a mangled
        // URL (escape token / backslashes / wrapping quotes) doesn't slip through here.
        let trimmed = WebBrowserStore.cleanURLLike(string)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Strip the fragment so the same page isn't visited twice under different anchors.
    private static func normalizeForVisit(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    private static func truncate(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max)) + "\n…[truncated]"
    }

    private static func fetchText(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 12
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = decompressPossiblyGzipped(data),
              let text = String(data: decoded, encoding: .utf8) else { return nil }
        return text
    }

    /// Decompress gzip data in place. Many sitemaps are served as `.xml.gz` with
    /// no `Content-Encoding: gzip` header, so URLSession will NOT transparently
    /// decode them — the bytes arrive as a raw gzip stream and a plain UTF-8
    /// decode returns nil. Detect the gzip magic bytes (1F 8B) and inflate via
    /// zlib; non-gzip input is returned unchanged, nil on a corrupt stream.
    private static func decompressPossiblyGzipped(_ data: Data) -> Data? {
        guard data.count > 2, data[0] == 0x1f, data[1] == 0x8b else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunkSize = 256 * 1024
        return data.withUnsafeBytes { src -> Data? in
            guard let base = src.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while true {
                var status: Int32 = Z_OK
                let produced = buffer.withUnsafeMutableBytes { dst -> Int in
                    stream.next_out = dst.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
                if status == Z_STREAM_END { return output }
                guard status == Z_OK || status == Z_BUF_ERROR else { return nil }
                if stream.avail_in == 0 && produced == 0 { return nil }
            }
        }
    }
}
