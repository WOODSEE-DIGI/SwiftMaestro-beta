import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native Bluesky / AT Protocol tools
//
// Public, read-only Bluesky queries via https://api.bsky.app (no authentication
// required for search/profile/feed/thread lookups). Auth-gated actions
// (posting, timelines, notifications) are out of scope for this initial set.

extension MaestroTools {

    static func registerBlueskyTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "search_bluesky_posts", spec: blueskyToolSpecs[0],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await searchBlueskyPosts(call) }),
            ToolDefinition(
                name: "get_bluesky_profile", spec: blueskyToolSpecs[1],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await getBlueskyProfile(call) }),
            ToolDefinition(
                name: "get_bluesky_author_feed", spec: blueskyToolSpecs[2],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await getBlueskyAuthorFeed(call) }),
            ToolDefinition(
                name: "get_bluesky_thread", spec: blueskyToolSpecs[3],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await getBlueskyThread(call) }),
            ToolDefinition(
                name: "search_bluesky_actors", spec: blueskyToolSpecs[4],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await searchBlueskyActors(call) }),
        ])
    }

    static var blueskyToolSpecs: [ToolSpec] {
        [
            rawSpec("search_bluesky_posts",
                "Search public Bluesky posts using the AT Protocol. Returns posts, authors, timestamps, and engagement counts.",
                properties: [
                    "query": ["type": "string", "description": "Search query string."],
                    "limit": ["type": "integer", "description": "Max posts to return (default 10, max 100)."],
                    "sort": ["type": "string", "description": "Sort order: 'top' or 'latest' (default 'latest')."],
                ], required: ["query"]),
            rawSpec("get_bluesky_profile",
                "Get a Bluesky actor profile (display name, bio, follower counts) by handle or DID.",
                properties: [
                    "actor": ["type": "string", "description": "Bluesky handle (e.g. 'alice.bsky.social') or DID."],
                ], required: ["actor"]),
            rawSpec("get_bluesky_author_feed",
                "Get recent posts from a specific Bluesky author.",
                properties: [
                    "actor": ["type": "string", "description": "Bluesky handle or DID."],
                    "limit": ["type": "integer", "description": "Max posts to return (default 10, max 100)."],
                ], required: ["actor"]),
            rawSpec("get_bluesky_thread",
                "Get a Bluesky post thread (the post and its replies) by its AT URI.",
                properties: [
                    "uri": ["type": "string", "description": "AT URI of the post, e.g. 'at://did:plc:.../app.bsky.feed.post/...'"],
                    "depth": ["type": "integer", "description": "Reply depth to fetch (default 3, max 10)."],
                ], required: ["uri"]),
            rawSpec("search_bluesky_actors",
                "Search public Bluesky user profiles.",
                properties: [
                    "query": ["type": "string", "description": "Search query string."],
                    "limit": ["type": "integer", "description": "Max users to return (default 10, max 100)."],
                ], required: ["query"]),
        ]
    }

    // MARK: - Args

    private struct SearchBlueskyPostsArgs: Decodable {
        let query: String?
        let limit: LenientInt?
        let sort: String?
    }

    private struct GetBlueskyProfileArgs: Decodable {
        let actor: String?
    }

    private struct GetBlueskyAuthorFeedArgs: Decodable {
        let actor: String?
        let limit: LenientInt?
    }

    private struct GetBlueskyThreadArgs: Decodable {
        let uri: String?
        let depth: LenientInt?
    }

    private struct SearchBlueskyActorsArgs: Decodable {
        let query: String?
        let limit: LenientInt?
    }

    // MARK: - API client

    private static let blueskyPublicBase = "https://api.bsky.app"
    private static let blueskyTimeout: TimeInterval = 20

    private static func blueskyRequest(path: String, query: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(string: blueskyPublicBase + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw NSError(domain: "Bluesky", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = blueskyTimeout
        request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Bluesky", code: -2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
        }
        return (data, http)
    }

    private static func blueskyJSON<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Implementations

    private static func searchBlueskyPosts(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SearchBlueskyPostsArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return errorJSON("search_bluesky_posts requires 'query'")
        }
        let limit = max(min(args.limit?.value ?? 10, 100), 1)
        let sort = (args.sort?.trimmingCharacters(in: .whitespaces).lowercased() == "top") ? "top" : "latest"

        do {
            let (data, http) = try await blueskyRequest(
                path: "/xrpc/app.bsky.feed.searchPosts",
                query: ["q": query, "limit": String(limit), "sort": sort]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Bluesky API returned \(http.statusCode)")
            }
            let payload = try blueskyJSON(data, as: BlueskySearchPostsResponse.self)
            return jsonString([
                "query": query,
                "sort": sort,
                "count": payload.posts.count,
                "posts": payload.posts.map { $0.asDictionary() },
            ])
        } catch {
            return errorJSON("Bluesky search failed: \(error.localizedDescription)")
        }
    }

    private static func getBlueskyProfile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GetBlueskyProfileArgs.self),
              let actor = args.actor?.trimmingCharacters(in: .whitespaces), !actor.isEmpty else {
            return errorJSON("get_bluesky_profile requires 'actor'")
        }
        do {
            let (data, http) = try await blueskyRequest(
                path: "/xrpc/app.bsky.actor.getProfile",
                query: ["actor": actor]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Bluesky API returned \(http.statusCode)")
            }
            let profile = try blueskyJSON(data, as: BlueskyProfile.self)
            return jsonString(profile.asDictionary())
        } catch {
            return errorJSON("Bluesky profile failed: \(error.localizedDescription)")
        }
    }

    private static func getBlueskyAuthorFeed(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GetBlueskyAuthorFeedArgs.self),
              let actor = args.actor?.trimmingCharacters(in: .whitespaces), !actor.isEmpty else {
            return errorJSON("get_bluesky_author_feed requires 'actor'")
        }
        let limit = max(min(args.limit?.value ?? 10, 100), 1)
        do {
            let (data, http) = try await blueskyRequest(
                path: "/xrpc/app.bsky.feed.getAuthorFeed",
                query: ["actor": actor, "limit": String(limit), "filter": "posts_no_replies"]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Bluesky API returned \(http.statusCode)")
            }
            let payload = try blueskyJSON(data, as: BlueskyAuthorFeedResponse.self)
            return jsonString([
                "actor": actor,
                "count": payload.feed.count,
                "posts": payload.feed.map { $0.post.asDictionary() },
            ])
        } catch {
            return errorJSON("Bluesky author feed failed: \(error.localizedDescription)")
        }
    }

    private static func getBlueskyThread(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GetBlueskyThreadArgs.self),
              let uri = args.uri?.trimmingCharacters(in: .whitespaces), !uri.isEmpty else {
            return errorJSON("get_bluesky_thread requires 'uri'")
        }
        let depth = max(min(args.depth?.value ?? 3, 10), 0)
        do {
            let (data, http) = try await blueskyRequest(
                path: "/xrpc/app.bsky.feed.getPostThread",
                query: ["uri": uri, "depth": String(depth)]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Bluesky API returned \(http.statusCode)")
            }
            let payload = try blueskyJSON(data, as: BlueskyThreadResponse.self)
            return jsonString([
                "uri": uri,
                "thread": payload.thread.asDictionary(),
            ])
        } catch {
            return errorJSON("Bluesky thread failed: \(error.localizedDescription)")
        }
    }

    private static func searchBlueskyActors(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SearchBlueskyActorsArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return errorJSON("search_bluesky_actors requires 'query'")
        }
        let limit = max(min(args.limit?.value ?? 10, 100), 1)
        do {
            let (data, http) = try await blueskyRequest(
                path: "/xrpc/app.bsky.actor.searchActors",
                query: ["q": query, "limit": String(limit)]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Bluesky API returned \(http.statusCode)")
            }
            let payload = try blueskyJSON(data, as: BlueskySearchActorsResponse.self)
            return jsonString([
                "query": query,
                "count": payload.actors.count,
                "actors": payload.actors.map { $0.asDictionary() },
            ])
        } catch {
            return errorJSON("Bluesky actor search failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Response models

    private struct BlueskySearchPostsResponse: Decodable {
        let posts: [BlueskyPost]
    }

    private struct BlueskyAuthorFeedResponse: Decodable {
        let feed: [BlueskyFeedItem]
    }

    private struct BlueskyFeedItem: Decodable {
        let post: BlueskyPost
    }

    private struct BlueskyThreadResponse: Decodable {
        let thread: BlueskyThreadNode
    }

    private struct BlueskySearchActorsResponse: Decodable {
        let actors: [BlueskyProfile]
    }

    private struct BlueskyPost: Decodable {
        let uri: String
        let cid: String
        let author: BlueskyAuthor
        let record: BlueskyRecord?
        let replyCount: Int?
        let repostCount: Int?
        let likeCount: Int?
        let quoteCount: Int?
        let indexedAt: String

        func asDictionary() -> [String: Any] {
            [
                "uri": uri,
                "cid": cid,
                "author": author.asDictionary(),
                "text": record?.text ?? "",
                "created_at": record?.createdAt ?? "",
                "reply_count": replyCount ?? 0,
                "repost_count": repostCount ?? 0,
                "like_count": likeCount ?? 0,
                "quote_count": quoteCount ?? 0,
                "indexed_at": indexedAt,
            ]
        }
    }

    private struct BlueskyAuthor: Decodable {
        let did: String
        let handle: String
        let displayName: String?
        let avatar: String?

        func asDictionary() -> [String: Any] {
            [
                "did": did,
                "handle": handle,
                "display_name": displayName ?? "",
                "avatar": avatar ?? "",
            ]
        }
    }

    private struct BlueskyRecord: Decodable {
        let text: String?
        let createdAt: String?
    }

    private struct BlueskyProfile: Decodable {
        let did: String
        let handle: String
        let displayName: String?
        let description: String?
        let avatar: String?
        let followersCount: Int?
        let followsCount: Int?
        let postsCount: Int?
        let indexedAt: String?

        func asDictionary() -> [String: Any] {
            [
                "did": did,
                "handle": handle,
                "display_name": displayName ?? "",
                "description": description ?? "",
                "avatar": avatar ?? "",
                "followers_count": followersCount ?? 0,
                "follows_count": followsCount ?? 0,
                "posts_count": postsCount ?? 0,
                "indexed_at": indexedAt ?? "",
            ]
        }
    }

    private struct BlueskyThreadNode: Decodable {
        let uri: String?
        let cid: String?
        let author: BlueskyAuthor?
        let record: BlueskyRecord?
        let replies: [BlueskyThreadNode]?
        let replyCount: Int?
        let repostCount: Int?
        let likeCount: Int?
        let quoteCount: Int?
        let indexedAt: String?

        func asDictionary() -> [String: Any] {
            var dict: [String: Any] = [
                "uri": uri ?? "",
                "cid": cid ?? "",
                "text": record?.text ?? "",
                "created_at": record?.createdAt ?? "",
                "reply_count": replyCount ?? 0,
                "repost_count": repostCount ?? 0,
                "like_count": likeCount ?? 0,
                "quote_count": quoteCount ?? 0,
                "indexed_at": indexedAt ?? "",
            ]
            if let author = author {
                dict["author"] = author.asDictionary()
            }
            if let replies = replies, !replies.isEmpty {
                dict["replies"] = replies.map { $0.asDictionary() }
            }
            return dict
        }
    }
}
