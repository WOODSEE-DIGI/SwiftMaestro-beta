import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - RSS reader tools
//
// Agent control over the RSS reader: subscribe to feeds, list articles, and
// sync YouTube watched state. Follows the same ToolRegistry pattern as the
// Pomodoro tools.

extension MaestroTools {

    static func registerRSSTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "rss_subscribe", spec: rssToolSpecs[0],
                category: ToolCategory.web.rawValue,
                handler: { call in await rssSubscribe(call) }),
            ToolDefinition(
                name: "rss_list_articles", spec: rssToolSpecs[1],
                category: ToolCategory.web.rawValue,
                handler: { call in await rssListArticles(call) }),
            ToolDefinition(
                name: "rss_mark_watched", spec: rssToolSpecs[2],
                category: ToolCategory.web.rawValue,
                handler: { call in await rssMarkWatched(call) }),
            ToolDefinition(
                name: "rss_refresh_feeds", spec: rssToolSpecs[3],
                category: ToolCategory.web.rawValue,
                handler: { call in await rssRefreshFeeds(call) }),
        ])
    }

    static var rssToolSpecs: [ToolSpec] {
        [
            rawSpec("rss_subscribe",
                "Subscribe the RSS reader to a feed URL. Fetches the feed, "
                + "creates a subscription, and imports the latest articles.",
                properties: [
                    "url": ["type": "string", "description": "The RSS or Atom feed URL."],
                    "folder": ["type": "string", "description": "Optional folder to organize the feed under."],
                ],
                required: ["url"]),
            rawSpec("rss_list_articles",
                "List recent articles from the RSS reader. Optionally filter by feed, folder, starred status, or unwatched YouTube videos.",
                properties: [
                    "feed_id": ["type": "string", "description": "Optional UUID of a specific feed."],
                    "folder": ["type": "string", "description": "Optional folder name to filter by."],
                    "starred_only": ["type": "boolean", "description": "If true, only return starred articles."],
                    "unwatched_youtube_only": ["type": "boolean", "description": "If true, only return unwatched YouTube videos from feeds."],
                    "limit": ["type": "integer", "description": "Maximum number of articles to return (default 20)."],
                ],
                required: []),
            rawSpec("rss_mark_watched",
                "Mark a YouTube video from an RSS feed as watched, or unmark it.",
                properties: [
                    "video_id": ["type": "string", "description": "The YouTube video ID."],
                    "watched": ["type": "boolean", "description": "True to mark watched, false to unmark."],
                ],
                required: ["video_id", "watched"]),
            rawSpec("rss_refresh_feeds",
                "Refresh all RSS subscriptions (or a specific feed) and update articles.",
                properties: [
                    "feed_id": ["type": "string", "description": "Optional UUID of a single feed to refresh. If omitted, all feeds are refreshed."],
                ],
                required: []),
        ]
    }

    // MARK: - Handlers

    private struct SubscribeArgs: Codable {
        let url: String?
        let folder: String?
    }

    private static func rssSubscribe(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SubscribeArgs.self),
              let urlString = args.url, !urlString.isEmpty else {
            return "Error: url is required."
        }
        do {
            let result = try await RSSFeedService.shared.fetchFeed(urlString: urlString)
            return await MainActor.run {
                let store = RSSReaderStore.shared
                let feed = store.addFeed(
                    title: result.feed.title,
                    url: result.feed.url,
                    siteURL: result.feed.siteURL,
                    folder: args.folder?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                store.upsertArticles(result.articles.map { var a = $0; a.feedID = feed.id; return a })
                YouTubeHistoryTracker.shared.scanAllArticles()
                return "Subscribed to '\(feed.title)' (\(result.articles.count) articles). Feed ID: \(feed.id.uuidString)"
            }
        } catch {
            return "Error subscribing to feed: \(error.localizedDescription)"
        }
    }

    private struct ListArgs: Codable {
        let feed_id: String?
        let folder: String?
        let starred_only: Bool?
        let unwatched_youtube_only: Bool?
        let limit: Int?
    }

    private static func rssListArticles(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ListArgs.self) else {
            return "Error: could not parse arguments."
        }
        return await MainActor.run {
            let store = RSSReaderStore.shared
            store.loadIfNeeded()

            var articles = store.articles
            if let feedIDString = args.feed_id, let feedID = UUID(uuidString: feedIDString) {
                articles = articles.filter { $0.feedID == feedID }
            }
            if let folder = args.folder, !folder.isEmpty {
                let feedIDs = store.feeds.filter { $0.folder == folder }.map { $0.id }
                articles = articles.filter { feedIDs.contains($0.feedID) }
            }
            if args.starred_only == true {
                articles = articles.filter { $0.isStarred }
            }
            if args.unwatched_youtube_only == true {
                let tracker = YouTubeHistoryTracker.shared
                articles = articles.filter {
                    guard let videoID = $0.youtubeVideoID else { return false }
                    return !tracker.isWatched(videoID: videoID)
                }
            }

            articles.sort { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
            let limit = max(1, min(args.limit ?? 20, 100))
            let slice = Array(articles.prefix(limit))

            let lines = slice.map { article in
                let feed = store.feed(id: article.feedID)
                let date = article.publishedDate?.ISO8601Format() ?? "no date"
                let youtube = article.youtubeVideoID.map { " [YouTube: \($0)]" } ?? ""
                return "- \(article.title) | \(feed?.title ?? "unknown feed") | \(date)\(youtube)"
            }
            return lines.isEmpty ? "No matching articles found." : lines.joined(separator: "\n")
        }
    }

    private struct MarkWatchedArgs: Codable {
        let video_id: String?
        let watched: Bool?
    }

    private static func rssMarkWatched(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: MarkWatchedArgs.self),
              let videoID = args.video_id, !videoID.isEmpty,
              let watched = args.watched else {
            return "Error: video_id and watched are required."
        }
        return await MainActor.run {
            let tracker = YouTubeHistoryTracker.shared
            if watched {
                tracker.markWatched(videoID: videoID, source: "agent")
                return "Marked \(videoID) as watched."
            } else {
                tracker.markUnwatched(videoID: videoID)
                return "Marked \(videoID) as unwatched."
            }
        }
    }

    private struct RefreshArgs: Codable {
        let feed_id: String?
    }

    private static func rssRefreshFeeds(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: RefreshArgs.self) else {
            return "Error: could not parse arguments."
        }

        let targets = await MainActor.run { () -> [RSSFeed] in
            let store = RSSReaderStore.shared
            store.loadIfNeeded()
            if let feedIDString = args.feed_id, let feedID = UUID(uuidString: feedIDString) {
                return store.feeds.filter { $0.id == feedID }
            }
            return store.feeds
        }

        guard !targets.isEmpty else { return "Error: no matching feeds found." }

        var total = 0
        var errors: [String] = []
        for feed in targets {
            do {
                let result = try await RSSFeedService.shared.fetchFeed(url: feed.url)
                await MainActor.run {
                    let store = RSSReaderStore.shared
                    store.updateFeed(result.feed)
                    store.upsertArticles(result.articles.map { var a = $0; a.feedID = feed.id; return a })
                }
                total += result.articles.count
            } catch {
                await MainActor.run {
                    var mutable = feed
                    mutable.lastFetchError = error.localizedDescription
                    RSSReaderStore.shared.updateFeed(mutable)
                }
                errors.append("\(feed.title): \(error.localizedDescription)")
            }
        }
        await MainActor.run {
            YouTubeHistoryTracker.shared.scanAllArticles()
        }
        var msg = "Refreshed \(targets.count) feed(s), imported \(total) articles."
        if !errors.isEmpty { msg += "\nErrors:\n" + errors.joined(separator: "\n") }
        return msg
    }
}
