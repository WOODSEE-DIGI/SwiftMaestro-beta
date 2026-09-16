import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URL {
    /// Returns a new URL with the scheme replaced, or nil if the string cannot be re-parsed.
    func replacingScheme(with scheme: String) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: true)
        components?.scheme = scheme
        return components?.url
    }
}

/// Fetches and parses RSS/Atom feeds and produces `RSSFeedFetchResult`s.
actor RSSFeedService {
    static let shared = RSSFeedService()

    private let session: URLSession
    private let parserDelegatePool = RSSParserDelegatePool()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadRevalidatingCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - Feed Fetch

    /// Fetches a feed URL and returns a populated `RSSFeed` plus its articles.
    /// HTTP URLs are upgraded to HTTPS when possible, with an HTTP fallback.
    func fetchFeed(url: URL) async throws -> RSSFeedFetchResult {
        let wasHTTP = url.scheme?.lowercased() == "http"
        let httpsURL = wasHTTP ? url.replacingScheme(with: "https") : url
        let fetchURL = httpsURL ?? url

        do {
            return try await performFetch(url: fetchURL, originalURL: url)
        } catch {
            if wasHTTP, let httpsURL, fetchURL != url {
                return try await performFetch(url: url, originalURL: url)
            }
            throw error
        }
    }

    /// Convenience: fetches a feed from a string URL.
    func fetchFeed(urlString: String) async throws -> RSSFeedFetchResult {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw RSSReaderError.invalidURL
        }
        return try await fetchFeed(url: url)
    }

    private func performFetch(url fetchURL: URL, originalURL: URL) async throws -> RSSFeedFetchResult {
        var request = URLRequest(url: fetchURL)
        request.setValue("SwiftMaestro-RSSReader/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RSSReaderError.parseFailed("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RSSReaderError.fetchFailed(statusCode: http.statusCode)
        }
        guard !data.isEmpty else {
            throw RSSReaderError.noData
        }

        let parser = XMLParser(data: data)
        let delegate = parserDelegatePool.acquire()
        parser.delegate = delegate
        guard parser.parse() else {
            parserDelegatePool.release(delegate)
            throw RSSReaderError.parseFailed(parser.parserError?.localizedDescription ?? "unknown XML error")
        }
        parserDelegatePool.release(delegate)

        let parsed = delegate.result
        var feed = RSSFeed(
            title: parsed.title ?? originalURL.absoluteString,
            url: originalURL,
            siteURL: parsed.link,
            description: parsed.description
        )
        feed.lastFetchDate = Date()

        let articles = parsed.items.map { item in
            let fallbackImage = item.imageURL ?? firstImageURL(in: item.content ?? item.summary)
            return RSSArticle(
                feedID: feed.id,
                title: item.title ?? "Untitled",
                summary: item.summary,
                contentHTML: item.content,
                url: item.link,
                author: item.author,
                publishedDate: item.published,
                categories: item.categories,
                guid: item.guid ?? item.link?.absoluteString,
                imageURL: fallbackImage
            )
        }

        return RSSFeedFetchResult(feed: feed, articles: articles)
    }

    // MARK: - OPML Import

    /// Parses an OPML body into a flat list of outlines with nested children preserved.
    func importOPML(data: Data) throws -> [RSSOPMLOutline] {
        let parser = XMLParser(data: data)
        let delegate = OPMLParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw RSSReaderError.parseFailed(parser.parserError?.localizedDescription ?? "OPML parse failed")
        }
        return delegate.outlines
    }

    /// Flattens an outline tree into feed subscriptions.
    func feeds(from outlines: [RSSOPMLOutline]) -> [RSSFeed] {
        var result: [RSSFeed] = []
        func visit(_ outline: RSSOPMLOutline, folder: String?) {
            if let xmlURL = outline.xmlURL {
                var feed = RSSFeed(title: outline.title, url: xmlURL, siteURL: outline.htmlURL, folder: folder)
                feed.dateAdded = Date()
                result.append(feed)
            }
            for child in outline.children {
                // Treat titled folders as folder names; untitled groups inherit parent folder.
                let childFolder = outline.xmlURL == nil ? (folder ?? outline.title) : folder
                visit(child, folder: childFolder)
            }
        }
        for outline in outlines { visit(outline, folder: nil) }
        return result
    }

    // MARK: - OPML Export

    /// Generates an OPML document from feeds grouped by folder.
    func exportOPML(feeds: [RSSFeed], title: String = "SwiftMaestro Subscriptions") -> Data? {
        let grouped = Dictionary(grouping: feeds) { $0.folder ?? "" }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<opml version=\"2.0\">\n"
        xml += "  <head><title>\(escaped(title))</title></head>\n"
        xml += "  <body>\n"

        let sortedFolders = grouped.keys.sorted()
        for folder in sortedFolders {
            let folderFeeds = grouped[folder] ?? []
            if folder.isEmpty {
                for feed in folderFeeds {
                    xml += outlineXML(for: feed)
                }
            } else {
                xml += "    <outline text=\"\(escaped(folder))\">\n"
                for feed in folderFeeds {
                    xml += outlineXML(for: feed, indent: "      ")
                }
                xml += "    </outline>\n"
            }
        }

        xml += "  </body>\n"
        xml += "</opml>\n"
        return xml.data(using: .utf8)
    }

    private func outlineXML(for feed: RSSFeed, indent: String = "    ") -> String {
        var attrs: [String] = []
        attrs.append("text=\"\(escaped(feed.title))\"")
        if let site = feed.siteURL?.absoluteString {
            attrs.append("htmlUrl=\"\(escaped(site))\"")
        }
        attrs.append("xmlUrl=\"\(escaped(feed.url.absoluteString))\"")
        return "\(indent)<outline \(attrs.joined(separator: " "))/>\n"
    }

    private func escaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - RSS/Atom Parser

/// Extracts the `src` of the first `<img>` tag from an HTML fragment.
private func firstImageURL(in html: String?) -> URL? {
    guard let html else { return nil }
    // Match `<img ... src="..." ...>` or `<img ... src='...' ...>`.
    guard let regex = try? NSRegularExpression(
        pattern: "<img[^>]+src=[\"']([^\"']+)[\"']",
        options: .caseInsensitive
    ) else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    if let match = regex.firstMatch(in: html, options: [], range: range),
       let srcRange = Range(match.range(at: 1), in: html) {
        let src = String(html[srcRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: src)
    }
    return nil
}

private final class RSSParserDelegate: NSObject, XMLParserDelegate {
    struct ParsedItem {
        var title: String?
        var summary: String?
        var content: String?
        var link: URL?
        var guid: String?
        var author: String?
        var published: Date?
        var categories: [String] = []
        var imageURL: URL?
    }

    struct ParsedFeed {
        var title: String?
        var link: URL?
        var description: String?
        var items: [ParsedItem] = []
    }

    private var resultFeed = ParsedFeed()
    private var currentItem: ParsedItem?
    private var elementStack: [String] = []
    private var currentText = ""
    private var isAtom = false
    private var feedLinkResolved = false
    private var inMediaGroup = false

    var result: ParsedFeed { resultFeed }

    func reset() {
        resultFeed = ParsedFeed()
        currentItem = nil
        elementStack.removeAll(keepingCapacity: false)
        currentText = ""
        isAtom = false
        feedLinkResolved = false
        inMediaGroup = false
    }

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        elementStack.append(elementName)
        currentText = ""

        let localName = qName ?? elementName
        let lower = localName.lowercased()

        if lower == "feed" {
            isAtom = true
        }

        if lower == "item" || lower == "entry" {
            currentItem = ParsedItem()
            inMediaGroup = false
        }

        if lower == "media:group" {
            inMediaGroup = true
        }

        if currentItem == nil, !feedLinkResolved,
           lower == "link" || lower == "atom:link" || elementName.lowercased() == "link" {
            if isAtom {
                if attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" {
                    if let href = attributeDict["href"] { resultFeed.link = URL(string: href) }
                }
            } else if let href = attributeDict["href"] {
                resultFeed.link = URL(string: href)
            }
        }

        if currentItem != nil {
            if inMediaGroup, lower == "media:thumbnail" {
                if let urlString = attributeDict["url"], let url = URL(string: urlString),
                   currentItem?.imageURL == nil {
                    currentItem?.imageURL = url
                }
            } else if inMediaGroup, lower == "media:content" {
                // Prefer the thumbnail, but accept an explicit image content if present.
                if let urlString = attributeDict["url"], let url = URL(string: urlString),
                   currentItem?.imageURL == nil,
                   let type = attributeDict["type"], type.hasPrefix("image") {
                    currentItem?.imageURL = url
                }
            } else if !inMediaGroup, lower == "media:content" || lower == "enclosure" {
                if let urlString = attributeDict["url"], let url = URL(string: urlString),
                   currentItem?.imageURL == nil {
                    currentItem?.imageURL = url
                }
            } else if !inMediaGroup, lower == "media:thumbnail" {
                if let urlString = attributeDict["url"], let url = URL(string: urlString),
                   currentItem?.imageURL == nil {
                    currentItem?.imageURL = url
                }
            } else if lower == "link" {
                if isAtom {
                    if attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" {
                        if let href = attributeDict["href"] { currentItem?.link = URL(string: href) }
                    }
                } else if attributeDict["rel"] == "enclosure" {
                    if let href = attributeDict["href"], let url = URL(string: href),
                       currentItem?.imageURL == nil {
                        currentItem?.imageURL = url
                    }
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        _ = elementStack.popLast()
        let localName = qName ?? elementName
        let lower = localName.lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if currentItem != nil {
            switch lower {
            case "title": currentItem?.title = trimmed
            case "description", "summary":
                if currentItem?.summary == nil { currentItem?.summary = trimmed }
            case "content:encoded", "content":
                if currentItem?.content == nil { currentItem?.content = trimmed }
            case "link":
                if isAtom {
                    // Atom link handled in didStartElement via attributes.
                } else if currentItem?.link == nil, let url = URL(string: trimmed) {
                    currentItem?.link = url
                }
            case "guid", "id": currentItem?.guid = trimmed
            case "author", "creator", "name":
                if currentItem?.author == nil { currentItem?.author = trimmed }
            case "pubdate", "published", "updated", "dc:date":
                if currentItem?.published == nil { currentItem?.published = RSSDateParser.parse(trimmed) }
            case "category", "dc:subject", "subject":
                if !trimmed.isEmpty {
                    let lowerTrimmed = trimmed.lowercased()
                    if !(currentItem?.categories.contains(where: { $0.lowercased() == lowerTrimmed }) ?? false) {
                        currentItem?.categories.append(trimmed)
                    }
                }
            case "media:description":
                if inMediaGroup {
                    if currentItem?.summary == nil { currentItem?.summary = trimmed }
                    if currentItem?.content == nil { currentItem?.content = trimmed }
                }
            default: break
            }

            if lower == "media:group" {
                inMediaGroup = false
            }

            if lower == "item" || lower == "entry" {
                if var item = currentItem {
                    item.categories = Array(Set(item.categories))
                    resultFeed.items.append(item)
                }
                inMediaGroup = false
                currentItem = nil
            }
        } else {
            switch lower {
            case "title": if resultFeed.title == nil { resultFeed.title = trimmed }
            case "description", "subtitle": if resultFeed.description == nil { resultFeed.description = trimmed }
            case "link":
                if !isAtom, resultFeed.link == nil, let url = URL(string: trimmed) {
                    resultFeed.link = url
                }
            default: break
            }
        }

        currentText = ""
    }
}

private final class RSSParserDelegatePool {
    private var delegates: [RSSParserDelegate] = []

    func acquire() -> RSSParserDelegate {
        let delegate = delegates.popLast() ?? RSSParserDelegate()
        delegate.reset()
        return delegate
    }

    func release(_ delegate: RSSParserDelegate) {
        delegates.append(delegate)
    }
}

// MARK: - OPML Parser

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    private var stack: [(outline: RSSOPMLOutline, children: [RSSOPMLOutline])] = []
    var outlines: [RSSOPMLOutline] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let lower = elementName.lowercased()
        guard lower == "outline" else { return }

        let title = attributeDict["text"] ?? attributeDict["title"] ?? "Untitled"
        let outline = RSSOPMLOutline(
            title: title,
            xmlURL: attributeDict["xmlUrl"].flatMap { URL(string: $0) },
            htmlURL: attributeDict["htmlUrl"].flatMap { URL(string: $0) }
        )
        stack.append((outline, []))
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let lower = elementName.lowercased()
        guard lower == "outline", let current = stack.popLast() else { return }

        var outline = current.outline
        outline.children = current.children

        if var parent = stack.last {
            parent.children.append(outline)
            stack[stack.count - 1] = parent
        } else {
            outlines.append(outline)
        }
    }
}

// MARK: - Date Parsing

private enum RSSDateParser {
    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssXXX",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd"
    ]

    static func parse(_ string: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: string) { return date }
        for format in formats {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
