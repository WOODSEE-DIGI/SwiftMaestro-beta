import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Tracks which YouTube videos discovered in RSS feeds have been watched, and
/// provides hooks to sync that state with external history sources.
@MainActor
final class YouTubeHistoryTracker {
    static let shared = YouTubeHistoryTracker()

    private let store = RSSReaderStore.shared

    private init() {}

    // MARK: - Discovery

    /// Scans all articles for YouTube links and registers them.
    func scanAllArticles() {
        store.loadIfNeeded()
        for article in store.articles {
            if let videoID = article.youtubeVideoID {
                store.registerYouTubeVideo(articleID: article.id, videoID: videoID, title: article.title)
            }
        }
    }

    /// Registers a YouTube video from an article if its URL contains one.
    @discardableResult
    func trackArticle(_ article: RSSArticle) -> RSSYouTubeVideo? {
        guard let videoID = article.youtubeVideoID else { return nil }
        return store.registerYouTubeVideo(articleID: article.id, videoID: videoID, title: article.title)
    }

    // MARK: - Watched State

    func isWatched(videoID: String) -> Bool {
        store.video(forVideoID: videoID)?.watchedAt != nil
    }

    func watchedDate(videoID: String) -> Date? {
        store.video(forVideoID: videoID)?.watchedAt
    }

    /// Marks a video as watched. This is called when the user opens a YouTube
    /// link from the reader, or when an external history source reports it.
    func markWatched(videoID: String, at date: Date = Date(), progressSeconds: Double? = nil, source: String = "reader", sourceURL: URL? = nil) {
        store.markVideoWatched(videoID: videoID, at: date, progressSeconds: progressSeconds)
        store.recordSync(videoID: videoID, source: source, sourceURL: sourceURL)
    }

    /// Unmarks a video as watched (user explicitly wants to re-watch).
    func markUnwatched(videoID: String) {
        store.unmarkVideoWatched(videoID: videoID)
    }

    // MARK: - History Sync Hooks

    /// Ingests a batch of watched YouTube video IDs from an external source.
    /// Deduplicates by video ID; the earliest watched date is kept.
    func syncWatchedVideoIDs(_ pairs: [(videoID: String, watchedAt: Date?, source: String, sourceURL: URL?)]) {
        store.loadIfNeeded()
        for pair in pairs {
            if let existing = store.video(forVideoID: pair.videoID),
               let existingDate = existing.watchedAt,
               let newDate = pair.watchedAt,
               newDate >= existingDate {
                continue
            }
            markWatched(videoID: pair.videoID, at: pair.watchedAt ?? Date(), source: pair.source, sourceURL: pair.sourceURL)
        }
    }

    /// Returns all unwatched YouTube videos from the feed, newest first.
    func unwatchedVideos() -> [RSSYouTubeVideo] {
        store.youTubeVideos
            .filter { $0.watchedAt == nil }
            .sorted { lhs, rhs in
                let lhsDate = store.article(id: lhs.articleID)?.publishedDate ?? .distantPast
                let rhsDate = store.article(id: rhs.articleID)?.publishedDate ?? .distantPast
                return lhsDate > rhsDate
            }
    }
}
