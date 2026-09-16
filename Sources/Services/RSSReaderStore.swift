import Foundation
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Central state and persistence for the RSS reader panel.
@Observable
@MainActor
final class RSSReaderStore {
    static let shared = RSSReaderStore()

    private(set) var feeds: [RSSFeed] = []
    private(set) var articles: [RSSArticle] = []
    private(set) var youTubeVideos: [RSSYouTubeVideo] = []
    private(set) var syncRecords: [RSSHistorySyncRecord] = []

    @ObservationIgnored
    private var isLoaded = false

    private init() {
        // Load persisted data immediately on first access so the store is ready
        // before any view reads it. Matches the pattern used by RemoteProviderStore.
        loadIfNeeded()
    }

    // MARK: - Public Accessors

    func feed(id: UUID) -> RSSFeed? { feeds.first { $0.id == id } }
    func article(id: UUID) -> RSSArticle? { articles.first { $0.id == id } }
    func articles(for feedID: UUID) -> [RSSArticle] {
        articles
            .filter { $0.feedID == feedID && isVisible($0) }
            .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
    }

    /// All visible articles across every feed, sorted by date.
    var allVisibleArticles: [RSSArticle] {
        articles
            .filter { isVisible($0) }
            .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
    }

    /// All categories that have appeared in articles for a feed, ignoring filters.
    func allCategories(for feedID: UUID) -> [String] {
        let all = articles.filter { $0.feedID == feedID }.flatMap { $0.categories }
        var seen = Set<String>()
        return all.filter {
            let key = $0.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }.sorted()
    }

    private func isVisible(_ article: RSSArticle) -> Bool {
        guard let feed = feed(id: article.feedID) else { return true }
        let articleCategories = article.categories.map { $0.lowercased() }
        if !feed.includedCategories.isEmpty {
            let included = feed.includedCategories.map { $0.lowercased() }
            guard articleCategories.contains(where: included.contains) else { return false }
        }
        if !feed.excludedCategories.isEmpty {
            let excluded = feed.excludedCategories.map { $0.lowercased() }
            if articleCategories.contains(where: excluded.contains) { return false }
        }
        return true
    }
    func video(for articleID: UUID) -> RSSYouTubeVideo? {
        youTubeVideos.first { $0.articleID == articleID }
    }
    func video(forVideoID videoID: String) -> RSSYouTubeVideo? {
        youTubeVideos.first { $0.videoID == videoID }
    }

    var unreadCount: Int { articles.filter { !$0.isRead }.count }
    var starredCount: Int { articles.filter { $0.isStarred }.count }

    // MARK: - Lifecycle

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        feeds = Self.loadFeeds()
        articles = Self.loadArticles()
        youTubeVideos = Self.loadYouTubeVideos()
        syncRecords = Self.loadSyncRecords()
    }

    // MARK: - Subscriptions

    func addFeed(title: String, url: URL, siteURL: URL? = nil, folder: String? = nil) -> RSSFeed {
        let feed = RSSFeed(title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: url, siteURL: siteURL, folder: folder?.trimmingCharacters(in: .whitespacesAndNewlines))
        if let existing = feeds.first(where: { $0.url == feed.url }) { return existing }
        feeds.append(feed)
        saveFeeds()
        return feed
    }

    func removeFeed(id: UUID) {
        feeds.removeAll { $0.id == id }
        articles.removeAll { $0.feedID == id }
        youTubeVideos.removeAll { video in
            articles.first { $0.id == video.articleID } == nil
        }
        saveFeeds()
        saveArticles()
        saveYouTubeVideos()
    }

    func updateFeed(_ feed: RSSFeed) {
        guard let index = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[index] = feed
        saveFeeds()
    }

    // MARK: - Articles

    func upsertArticles(_ newArticles: [RSSArticle]) {
        var changed = false
        for article in newArticles {
            if let index = articles.firstIndex(where: { $0.guid == article.guid && $0.feedID == article.feedID }) {
                // Preserve local state (read/starred) while updating metadata.
                var updated = article
                updated.id = articles[index].id
                updated.isRead = articles[index].isRead
                updated.isStarred = articles[index].isStarred
                updated.isHidden = articles[index].isHidden
                // Merge newly parsed categories with any existing ones, avoiding duplicates.
                let existingCategories = Set(articles[index].categories.map { $0.lowercased() })
                let newCategories = article.categories.filter { !existingCategories.contains($0.lowercased()) }
                updated.categories = articles[index].categories + newCategories
                // Preserve an existing image URL if the refresh didn't provide one.
                updated.imageURL = article.imageURL ?? articles[index].imageURL
                articles[index] = updated
            } else {
                articles.append(article)
                changed = true
            }
        }
        if changed { saveArticles() }
        else { saveArticles() } // Always save in case metadata changed.
    }

    /// Removes articles whose feedID no longer matches any subscribed feed.
    /// Used to clean up phantom articles created before refresh reused feed IDs.
    func pruneOrphanedArticles() {
        let validIDs = Set(feeds.map(\.id))
        let before = articles.count
        articles.removeAll { !validIDs.contains($0.feedID) }
        if articles.count != before {
            saveArticles()
        }
    }

    func markRead(articleID: UUID, read: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }) else { return }
        articles[index].isRead = read
        saveArticles()
    }

    func markStarred(articleID: UUID, starred: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }) else { return }
        articles[index].isStarred = starred
        saveArticles()
    }

    func markAllRead(in feedID: UUID? = nil) {
        let visibleIDs: Set<UUID> = if let feedID = feedID {
            Set(articles(for: feedID).map(\.id))
        } else {
            Set(allVisibleArticles.map(\.id))
        }
        for index in articles.indices {
            guard visibleIDs.contains(articles[index].id) else { continue }
            articles[index].isRead = true
        }
        saveArticles()
    }

    // MARK: - YouTube Tracking

    /// Registers a YouTube video discovered in an article.
    @discardableResult
    func registerYouTubeVideo(articleID: UUID, videoID: String, title: String? = nil) -> RSSYouTubeVideo {
        if let existing = youTubeVideos.first(where: { $0.videoID == videoID }) {
            return existing
        }
        let video = RSSYouTubeVideo(articleID: articleID, videoID: videoID, title: title)
        youTubeVideos.append(video)
        saveYouTubeVideos()
        return video
    }

    func markVideoWatched(videoID: String, at date: Date = Date(), progressSeconds: Double? = nil) {
        guard let index = youTubeVideos.firstIndex(where: { $0.videoID == videoID }) else { return }
        youTubeVideos[index].watchedAt = date
        youTubeVideos[index].watchProgressSeconds = progressSeconds
        saveYouTubeVideos()
    }

    func unmarkVideoWatched(videoID: String) {
        guard let index = youTubeVideos.firstIndex(where: { $0.videoID == videoID }) else { return }
        youTubeVideos[index].watchedAt = nil
        youTubeVideos[index].watchProgressSeconds = nil
        saveYouTubeVideos()
    }

    func recordSync(videoID: String, source: String, sourceURL: URL? = nil) {
        syncRecords.append(RSSHistorySyncRecord(videoID: videoID, source: source, sourceURL: sourceURL))
        saveSyncRecords()
    }

    // MARK: - Persistence

    func saveFeeds() { Self.save(feeds, to: Self.feedsFile) }
    func saveArticles() { Self.save(articles, to: Self.articlesFile) }
    func saveYouTubeVideos() { Self.save(youTubeVideos, to: Self.videosFile) }
    func saveSyncRecords() { Self.save(syncRecords, to: Self.syncFile) }

    private nonisolated static var readerDir: URL {
        let base = WorkspaceStore.dataDir().appendingPathComponent("rss-reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private nonisolated static var feedsFile: URL { readerDir.appendingPathComponent("feeds.json") }
    private nonisolated static var articlesFile: URL { readerDir.appendingPathComponent("articles.json") }
    private nonisolated static var videosFile: URL { readerDir.appendingPathComponent("youtube-videos.json") }
    private nonisolated static var syncFile: URL { readerDir.appendingPathComponent("sync-records.json") }

    private nonisolated static func load<T: Codable>(from url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private nonisolated static func save<T: Codable>(_ value: [T], to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[PERSIST] RSS reader save failed at \(url.path): \(error.localizedDescription)")
        }
    }

    private nonisolated static func loadFeeds() -> [RSSFeed] { load(from: feedsFile) }
    private nonisolated static func loadArticles() -> [RSSArticle] { load(from: articlesFile) }
    private nonisolated static func loadYouTubeVideos() -> [RSSYouTubeVideo] { load(from: videosFile) }
    private nonisolated static func loadSyncRecords() -> [RSSHistorySyncRecord] { load(from: syncFile) }
}
