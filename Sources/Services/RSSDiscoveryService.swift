import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Discovers RSS/Atom feeds for a website by:
/// 1. Parsing `<link rel="alternate" type="application/rss+xml|atom+xml">` tags.
/// 2. Probing common feed paths (e.g. `/rss`, `/feed`, `/rss.xml`).
///
/// Declared links are always returned (even if unreachable) so users can still
/// subscribe to paywalled or slow feeds. Guessed paths are only returned after
/// successfully fetching and parsing the feed.
actor RSSDiscoveryService {
    static let shared = RSSDiscoveryService()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadRevalidatingCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Discovers feeds by fetching the HTML of the given site URL.
    func discoverFeeds(fromSiteURL siteURL: URL) async -> [RSSDiscoveredFeed] {
        guard let html = await fetchHTML(from: siteURL) else { return [] }
        return await discoverFeeds(html: html, baseURL: siteURL)
    }

    /// Discovers feeds from already-captured HTML.
    func discoverFeeds(html: String, baseURL: URL) async -> [RSSDiscoveredFeed] {
        let declared = parseDeclaredLinks(in: html, baseURL: baseURL)
        return await discoverFeeds(declaredLinks: declared, baseURL: baseURL)
    }

    /// Discovers feeds from already-known `<link>` declarations plus common paths.
    /// Used by SwiftBrowser when it can extract links directly from the page.
    func discoverFeeds(
        declaredLinks: [(url: URL, type: String?, title: String?)],
        baseURL: URL
    ) async -> [RSSDiscoveredFeed] {
        let base = feedBaseURL(for: baseURL)

        var candidates: [(url: URL, kind: RSSDiscoveredFeed.Kind, source: RSSDiscoveredFeed.Source, declaredTitle: String?)] = []
        var seen = Set<String>()

        for link in declaredLinks {
            let normalized = canonicalString(for: link.url)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            let kind = feedKind(for: link.type)
            candidates.append((link.url, kind, .link, link.title))
        }

        for path in Self.commonPaths {
            guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { continue }
            let normalized = canonicalString(for: url)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            candidates.append((url, .rss, .guessed(path: path), nil))
        }

        return await validate(candidates: candidates)
    }

    // MARK: - HTML fetching

    private func fetchHTML(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue("SwiftMaestro-RSSDiscovery/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii)
        } catch {
            return nil
        }
    }

    // MARK: - HTML parsing

    private func parseDeclaredLinks(
        in html: String,
        baseURL: URL
    ) -> [(url: URL, type: String?, title: String?)] {
        let pattern = #"<link\b[^>]*rel=["']alternate["'][^>]*>"#
        let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        return matches.compactMap { match -> (url: URL, type: String?, title: String?)? in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])

            guard let type = attributeValue(named: "type", in: tag)?.lowercased(),
                  type.contains("rss") || type.contains("atom") else { return nil }

            guard let href = attributeValue(named: "href", in: tag),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { return nil }

            let title = attributeValue(named: "title", in: tag)
            return (url, type, title)
        }
    }

    private func attributeValue(named name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"=["']([^"']*)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[valueRange])
    }

    // MARK: - Common paths

    private static let commonPaths: [String] = [
        "rss",
        "feed",
        "feeds",
        "rss.xml",
        "feed.xml",
        "atom.xml",
        "index.xml",
        "?feed=rss2",
        "feed/rss",
        "feeds/default.rss"
    ]

    private func feedBaseURL(for siteURL: URL) -> URL {
        var url = siteURL
        // If the URL points at a file (e.g. /blog/post.html), start from the directory.
        if !url.pathExtension.isEmpty {
            url = url.deletingLastPathComponent()
        }
        // Ensure a trailing slash so relative paths resolve into this directory.
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        var path = components?.path ?? "/"
        if !path.hasSuffix("/") { path.append("/") }
        components?.path = path
        return components?.url ?? url
    }

    // MARK: - Validation

    private func validate(
        candidates: [(url: URL, kind: RSSDiscoveredFeed.Kind, source: RSSDiscoveredFeed.Source, declaredTitle: String?)]
    ) async -> [RSSDiscoveredFeed] {
        var results: [RSSDiscoveredFeed] = []
        var seen = Set<String>()

        for candidate in candidates {
            let normalized = canonicalString(for: candidate.url)
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            do {
                let fetched = try await RSSFeedService.shared.fetchFeed(url: candidate.url)
                results.append(RSSDiscoveredFeed(
                    title: fetched.feed.title,
                    url: candidate.url,
                    siteURL: fetched.feed.siteURL,
                    kind: candidate.kind,
                    source: candidate.source
                ))
            } catch {
                // Declared links are surfaced even if unreachable; guesses are dropped.
                if case .link = candidate.source {
                    let fallback = candidate.declaredTitle?.isEmpty == false
                        ? candidate.declaredTitle!
                        : candidate.url.lastPathComponent
                    results.append(RSSDiscoveredFeed(
                        title: fallback,
                        url: candidate.url,
                        siteURL: nil,
                        kind: candidate.kind,
                        source: candidate.source
                    ))
                }
            }
        }

        return results
    }

    // MARK: - Helpers

    private func feedKind(for type: String?) -> RSSDiscoveredFeed.Kind {
        guard let type else { return .rss }
        return type.lowercased().contains("atom") ? .atom : .rss
    }

    private func canonicalString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}
