import Foundation

// MARK: - Feed

/// A subscribed RSS/Atom feed.
struct RSSFeed: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var url: URL
    var siteURL: URL?
    var iconURL: URL?
    var folder: String?
    var description: String?
    var lastFetchDate: Date?
    var lastFetchError: String?
    var isArchived: Bool = false
    var dateAdded: Date = Date()

    /// If non-empty, only articles whose categories intersect with this list are shown.
    var includedCategories: [String] = []
    /// Articles whose categories intersect with this list are hidden.
    var excludedCategories: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, title, url, siteURL, iconURL, folder, description
        case lastFetchDate, lastFetchError, isArchived, dateAdded
        case includedCategories, excludedCategories
    }

    init(title: String, url: URL, siteURL: URL? = nil, iconURL: URL? = nil,
         folder: String? = nil, description: String? = nil) {
        self.title = title
        self.url = url
        self.siteURL = siteURL
        self.iconURL = iconURL
        self.folder = folder
        self.description = description
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        siteURL = try container.decodeIfPresent(URL.self, forKey: .siteURL)
        iconURL = try container.decodeIfPresent(URL.self, forKey: .iconURL)
        folder = try container.decodeIfPresent(String.self, forKey: .folder)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        lastFetchDate = try container.decodeIfPresent(Date.self, forKey: .lastFetchDate)
        lastFetchError = try container.decodeIfPresent(String.self, forKey: .lastFetchError)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        includedCategories = try container.decodeIfPresent([String].self, forKey: .includedCategories) ?? []
        excludedCategories = try container.decodeIfPresent([String].self, forKey: .excludedCategories) ?? []
    }
}

// MARK: - Article

/// A single item from a feed.
struct RSSArticle: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var feedID: UUID
    var title: String
    var summary: String?
    var contentHTML: String?
    var url: URL?
    var author: String?
    var publishedDate: Date?
    var fetchedDate: Date = Date()
    var isRead: Bool = false
    var isStarred: Bool = false
    var isHidden: Bool = false

    /// Categories / tags attached to the article (e.g. Guardian RSS `<category>` tags).
    var categories: [String] = []

    /// Stable identity used for de-duplication when re-fetching a feed.
    var guid: String?

    /// Lead image URL from `<media:content>`, `<enclosure>`, or the first `<img>` in the content.
    var imageURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, feedID, title, summary, contentHTML, url, author
        case publishedDate, fetchedDate, isRead, isStarred, isHidden
        case categories, guid, imageURL
    }

    init(id: UUID = UUID(), feedID: UUID, title: String, summary: String? = nil,
         contentHTML: String? = nil, url: URL? = nil, author: String? = nil,
         publishedDate: Date? = nil, fetchedDate: Date = Date(), isRead: Bool = false,
         isStarred: Bool = false, isHidden: Bool = false, categories: [String] = [],
         guid: String? = nil, imageURL: URL? = nil) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.summary = summary
        self.contentHTML = contentHTML
        self.url = url
        self.author = author
        self.publishedDate = publishedDate
        self.fetchedDate = fetchedDate
        self.isRead = isRead
        self.isStarred = isStarred
        self.isHidden = isHidden
        self.categories = categories
        self.guid = guid
        self.imageURL = imageURL
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        feedID = try container.decode(UUID.self, forKey: .feedID)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        contentHTML = try container.decodeIfPresent(String.self, forKey: .contentHTML)
        url = try container.decodeIfPresent(URL.self, forKey: .url)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        publishedDate = try container.decodeIfPresent(Date.self, forKey: .publishedDate)
        fetchedDate = try container.decodeIfPresent(Date.self, forKey: .fetchedDate) ?? Date()
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        categories = try container.decodeIfPresent([String].self, forKey: .categories) ?? []
        guid = try container.decodeIfPresent(String.self, forKey: .guid)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
    }
}

// MARK: - YouTube Video

/// Tracks a YouTube video that appeared in a feed and its watched state.
struct RSSYouTubeVideo: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var articleID: UUID
    var videoID: String
    var title: String?
    var watchedAt: Date?
    var watchProgressSeconds: Double?
    var lastSyncedAt: Date?
}

// MARK: - Sync Record

/// Marks when a video's watched state was synced from a specific source.
struct RSSHistorySyncRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var videoID: String
    var source: String
    var sourceURL: URL?
    var syncedAt: Date = Date()
}

// MARK: - Discovered Feed

/// A feed candidate found by RSS auto-discovery on a website.
struct RSSDiscoveredFeed: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    var siteURL: URL?
    var kind: Kind
    var source: Source

    enum Kind: String, Codable, Hashable {
        case rss
        case atom
    }

    enum Source: Hashable {
        /// Declared in the page's `<link rel="alternate">` tag.
        case link
        /// Guessed from a common feed path.
        case guessed(path: String)
    }
}

// MARK: - OPML

/// Lightweight outline node used for OPML import/export.
struct RSSOPMLOutline: Codable, Sendable {
    var title: String
    var xmlURL: URL?
    var htmlURL: URL?
    var children: [RSSOPMLOutline] = []
}

// MARK: - Feed Fetch Result

/// Result of fetching one feed.
struct RSSFeedFetchResult {
    var feed: RSSFeed
    var articles: [RSSArticle]
}

// MARK: - Errors

enum RSSReaderError: LocalizedError {
    case invalidURL
    case fetchFailed(statusCode: Int)
    case parseFailed(String)
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The feed URL is invalid."
        case .fetchFailed(let code): return "Server returned HTTP \(code)."
        case .parseFailed(let msg): return "Parse failed: \(msg)"
        case .noData: return "The feed returned no data."
        }
    }
}

// MARK: - URL Helpers

extension RSSArticle {
    /// Extracts a YouTube video ID from the article URL if present.
    var youtubeVideoID: String? {
        guard let url else { return nil }
        return YouTubeURLParser.videoID(from: url)
    }
}

enum YouTubeURLParser {
    static func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        guard host.contains("youtube.com") || host.contains("youtu.be") else { return nil }

        if host.contains("youtu.be") {
            return url.pathComponents.dropFirst().first { !$0.isEmpty }
        }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryItems = components.queryItems,
           let v = queryItems.first(where: { $0.name == "v" })?.value,
           !v.isEmpty {
            return v
        }

        if url.pathComponents.count > 2,
           url.pathComponents[1].lowercased() == "embed" {
            return url.pathComponents[2]
        }

        return nil
    }

    static func youTubeURL(for videoID: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }
}
