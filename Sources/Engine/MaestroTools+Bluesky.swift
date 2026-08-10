import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native Bluesky / AT Protocol tools
//
// Public, read-only Bluesky queries via https://api.bsky.app (no authentication
// required for search/profile/feed/thread lookups). Authenticated actions
// (timeline, posting, like/repost) reuse the session the user created in the
// Bluesky plugin panel — tokens live in the Keychain under plugin.bluesky.*,
// so signing in once in the panel enables these agent tools too.

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
            ToolDefinition(
                name: "get_bluesky_timeline", spec: blueskyToolSpecs[5],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await getBlueskyTimeline(call) }),
            ToolDefinition(
                name: "post_bluesky", spec: blueskyToolSpecs[6],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await postBluesky(call) }),
            ToolDefinition(
                name: "like_bluesky_post", spec: blueskyToolSpecs[7],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await likeBlueskyPost(call) }),
            ToolDefinition(
                name: "unlike_bluesky_post", spec: blueskyToolSpecs[8],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await unlikeBlueskyPost(call) }),
            ToolDefinition(
                name: "repost_bluesky_post", spec: blueskyToolSpecs[9],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await repostBlueskyPost(call) }),
            ToolDefinition(
                name: "unrepost_bluesky_post", spec: blueskyToolSpecs[10],
                category: ToolCategory.bluesky.rawValue,
                handler: { call in await unrepostBlueskyPost(call) }),
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
            rawSpec("get_bluesky_timeline",
                "Get the signed-in user's Bluesky home timeline. Requires sign-in via the Bluesky plugin panel.",
                properties: [
                    "limit": ["type": "integer", "description": "Max posts to return (default 20, max 100)."],
                ], required: []),
            rawSpec("post_bluesky",
                "Create a Bluesky post as the signed-in user (max 300 characters). URLs in the text become clickable links automatically. Requires sign-in via the Bluesky plugin panel.",
                properties: [
                    "text": ["type": "string", "description": "Post text, max 300 characters."],
                ], required: ["text"]),
            rawSpec("like_bluesky_post",
                "Like a Bluesky post as the signed-in user. Returns the like record URI (needed to unlike). Requires sign-in via the Bluesky plugin panel.",
                properties: [
                    "uri": ["type": "string", "description": "AT URI of the post to like."],
                    "cid": ["type": "string", "description": "CID of the post to like."],
                ], required: ["uri", "cid"]),
            rawSpec("unlike_bluesky_post",
                "Remove a like from a Bluesky post. Requires sign-in via the Bluesky plugin panel.",
                properties: [
                    "like_uri": ["type": "string", "description": "AT URI of the like record to delete (returned by like_bluesky_post or the post's viewer state)."],
                ], required: ["like_uri"]),
            rawSpec("repost_bluesky_post",
                "Repost a Bluesky post as the signed-in user. Returns the repost record URI (needed to undo). Requires sign-in via the Bluesky plugin panel.",
                properties: [
                    "uri": ["type": "string", "description": "AT URI of the post to repost."],
                    "cid": ["type": "string", "description": "CID of the post to repost."],
                ], required: ["uri", "cid"]),
            rawSpec("unrepost_bluesky_post",
                "Undo a repost on Bluesky. Requires sign-in via the Bluesky plugin panel.",
                properties: [
                    "repost_uri": ["type": "string", "description": "AT URI of the repost record to delete (returned by repost_bluesky_post or the post's viewer state)."],
                ], required: ["repost_uri"]),
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

    // MARK: - Authenticated session (shared with the Bluesky plugin panel)
    //
    // The plugin stores its session in the Keychain under plugin.bluesky.*
    // (see PluginBridge's per-plugin namespace). These tools read the same
    // entries, so the user signs in once in the panel and agents can act on
    // their behalf. Refreshing a token here writes it back to the same place.

    private struct BlueskySession {
        let pds: String
        let did: String
        let handle: String
        let accessJwt: String
        let refreshJwt: String
    }

    private enum BlueskyAuthError: LocalizedError {
        case notSignedIn
        case refreshFailed
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Not signed in to Bluesky. Sign in via the Bluesky plugin panel first (handle + app password)."
            case .refreshFailed:
                return "Bluesky session refresh failed — sign in again via the Bluesky plugin panel."
            case .requestFailed(let detail):
                return detail
            }
        }
    }

    private static func loadBlueskySession() -> BlueskySession? {
        guard
            let access = try? KeychainService.read(account: "plugin.bluesky.accessJwt"),
            !access.isEmpty,
            let refresh = try? KeychainService.read(account: "plugin.bluesky.refreshJwt"),
            !refresh.isEmpty,
            let did = try? KeychainService.read(account: "plugin.bluesky.did"),
            !did.isEmpty
        else { return nil }
        let pds = (try? KeychainService.read(account: "plugin.bluesky.pds")) ?? nil
        let handle = (try? KeychainService.read(account: "plugin.bluesky.handle")) ?? nil
        return BlueskySession(
            pds: (pds?.isEmpty == false) ? pds! : "https://bsky.social",
            did: did,
            handle: handle ?? "",
            accessJwt: access,
            refreshJwt: refresh
        )
    }

    /// Authenticated XRPC request against the user's PDS. On an ExpiredToken
    /// response it refreshes the session once (writing new tokens back to the
    /// plugin's Keychain entries) and retries the original request once.
    private static func blueskyAuthedRequest(
        path: String,
        query: [String: String]?,
        body: [String: Any]?,
        retryOnExpired: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        guard let session = loadBlueskySession() else { throw BlueskyAuthError.notSignedIn }

        var components = URLComponents(string: session.pds + path)!
        if let query {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw BlueskyAuthError.requestFailed("Invalid Bluesky request URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = blueskyTimeout
        request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(session.accessJwt)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BlueskyAuthError.requestFailed("Non-HTTP response from Bluesky")
        }

        if retryOnExpired, blueskyIsExpiredToken(data: data, status: http.statusCode) {
            try await refreshBlueskySession()
            return try await blueskyAuthedRequest(
                path: path, query: query, body: body, retryOnExpired: false)
        }
        return (data, http)
    }

    private static func blueskyIsExpiredToken(data: Data, status: Int) -> Bool {
        guard status == 400,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? String
        else { return false }
        return error == "ExpiredToken"
    }

    private static func refreshBlueskySession() async throws {
        guard let session = loadBlueskySession() else { throw BlueskyAuthError.notSignedIn }
        guard let url = URL(string: session.pds + "/xrpc/com.atproto.server.refreshSession") else {
            throw BlueskyAuthError.requestFailed("Invalid PDS URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = blueskyTimeout
        request.setValue("Bearer \(session.refreshJwt)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BlueskyAuthError.refreshFailed
        }
        struct RefreshResponse: Decodable {
            let accessJwt: String
            let refreshJwt: String?
        }
        let parsed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        try KeychainService.store(
            account: "plugin.bluesky.accessJwt", value: parsed.accessJwt, synchronizable: false)
        if let refresh = parsed.refreshJwt, !refresh.isEmpty {
            try KeychainService.store(
                account: "plugin.bluesky.refreshJwt", value: refresh, synchronizable: false)
        }
    }

    // MARK: - Authenticated implementations

    private struct GetBlueskyTimelineArgs: Decodable {
        let limit: LenientInt?
    }

    private struct PostBlueskyArgs: Decodable {
        let text: String?
    }

    private struct BlueskyRecordActionArgs: Decodable {
        let uri: String?
        let cid: String?
    }

    private struct BlueskyUndoActionArgs: Decodable {
        let likeUri: String?
        let repostUri: String?

        private enum CodingKeys: String, CodingKey {
            case likeUri = "like_uri"
            case repostUri = "repost_uri"
        }
    }

    private struct BlueskyCreateRecordResponse: Decodable {
        let uri: String
        let cid: String
    }

    private static func getBlueskyTimeline(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: GetBlueskyTimelineArgs.self)
        let limit = max(min(args?.limit?.value ?? 20, 100), 1)
        do {
            let (data, http) = try await blueskyAuthedRequest(
                path: "/xrpc/app.bsky.feed.getTimeline",
                query: ["limit": String(limit)],
                body: nil
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Bluesky API returned \(http.statusCode)")
            }
            let payload = try blueskyJSON(data, as: BlueskyAuthorFeedResponse.self)
            return jsonString([
                "count": payload.feed.count,
                "posts": payload.feed.map { $0.post.asDictionary() },
            ])
        } catch {
            return errorJSON("Bluesky timeline failed: \(error.localizedDescription)")
        }
    }

    private static func postBluesky(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PostBlueskyArgs.self),
              let text = args.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return errorJSON("post_bluesky requires 'text'") }
        // Bluesky's limit is 300 grapheme clusters — Swift's String.count
        // counts exactly those.
        guard text.count <= 300 else {
            return errorJSON("post_bluesky text is \(text.count) characters; the limit is 300")
        }
        guard let session = loadBlueskySession() else {
            return errorJSON(BlueskyAuthError.notSignedIn.localizedDescription)
        }
        do {
            var record: [String: Any] = [
                "$type": "app.bsky.feed.post",
                "text": text,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ]
            let facets = detectBlueskyLinkFacets(in: text)
            if !facets.isEmpty { record["facets"] = facets }
            let (data, http) = try await blueskyAuthedRequest(
                path: "/xrpc/com.atproto.repo.createRecord",
                query: nil,
                body: [
                    "repo": session.did,
                    "collection": "app.bsky.feed.post",
                    "record": record,
                ]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Bluesky post failed with status \(http.statusCode)")
            }
            let created = try blueskyJSON(data, as: BlueskyCreateRecordResponse.self)
            return jsonString(["posted": true, "uri": created.uri, "cid": created.cid])
        } catch {
            return errorJSON("Bluesky post failed: \(error.localizedDescription)")
        }
    }

    private static func likeBlueskyPost(_ call: ToolCall) async -> String {
        await createBlueskySubjectRecord(
            call, collection: "app.bsky.feed.like", actionName: "like_bluesky_post")
    }

    private static func repostBlueskyPost(_ call: ToolCall) async -> String {
        await createBlueskySubjectRecord(
            call, collection: "app.bsky.feed.repost", actionName: "repost_bluesky_post")
    }

    private static func unlikeBlueskyPost(_ call: ToolCall) async -> String {
        await deleteBlueskyRecord(
            call, uriKeyPath: \.likeUri, collection: "app.bsky.feed.like",
            actionName: "unlike_bluesky_post")
    }

    private static func unrepostBlueskyPost(_ call: ToolCall) async -> String {
        await deleteBlueskyRecord(
            call, uriKeyPath: \.repostUri, collection: "app.bsky.feed.repost",
            actionName: "unrepost_bluesky_post")
    }

    /// Shared handler for like/repost: both are createRecord calls whose
    /// record is just { subject: { uri, cid }, createdAt }.
    private static func createBlueskySubjectRecord(
        _ call: ToolCall, collection: String, actionName: String
    ) async -> String {
        guard let args = decodeArgs(call, as: BlueskyRecordActionArgs.self),
              let uri = args.uri?.trimmingCharacters(in: .whitespaces),
              !uri.isEmpty,
              let cid = args.cid?.trimmingCharacters(in: .whitespaces),
              !cid.isEmpty
        else { return errorJSON("\(actionName) requires 'uri' and 'cid'") }
        guard let session = loadBlueskySession() else {
            return errorJSON(BlueskyAuthError.notSignedIn.localizedDescription)
        }
        do {
            let (data, http) = try await blueskyAuthedRequest(
                path: "/xrpc/com.atproto.repo.createRecord",
                query: nil,
                body: [
                    "repo": session.did,
                    "collection": collection,
                    "record": [
                        "$type": collection,
                        "subject": ["uri": uri, "cid": cid],
                        "createdAt": ISO8601DateFormatter().string(from: Date()),
                    ],
                ]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("\(actionName) failed with status \(http.statusCode)")
            }
            let created = try blueskyJSON(data, as: BlueskyCreateRecordResponse.self)
            return jsonString([
                "ok": true, "collection": collection, "record_uri": created.uri,
            ])
        } catch {
            return errorJSON("\(actionName) failed: \(error.localizedDescription)")
        }
    }

    /// Shared handler for unlike/unrepost: deleteRecord by the record's own
    /// AT URI (the rkey is its final path segment).
    private static func deleteBlueskyRecord(
        _ call: ToolCall,
        uriKeyPath: KeyPath<BlueskyUndoActionArgs, String?>,
        collection: String,
        actionName: String
    ) async -> String {
        guard let args = decodeArgs(call, as: BlueskyUndoActionArgs.self),
              let recordURI = args[keyPath: uriKeyPath]?.trimmingCharacters(in: .whitespaces),
              !recordURI.isEmpty
        else { return errorJSON("\(actionName) requires the record URI to delete") }
        guard recordURI.hasPrefix("at://"), recordURI.contains("/\(collection)/"),
              let rkey = recordURI.split(separator: "/").last, !rkey.isEmpty
        else { return errorJSON("\(actionName) got an invalid \(collection) record URI") }
        guard let session = loadBlueskySession() else {
            return errorJSON(BlueskyAuthError.notSignedIn.localizedDescription)
        }
        do {
            let (_, http) = try await blueskyAuthedRequest(
                path: "/xrpc/com.atproto.repo.deleteRecord",
                query: nil,
                body: [
                    "repo": session.did,
                    "collection": collection,
                    "rkey": String(rkey),
                ]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("\(actionName) failed with status \(http.statusCode)")
            }
            return jsonString(["ok": true, "deleted": recordURI])
        } catch {
            return errorJSON("\(actionName) failed: \(error.localizedDescription)")
        }
    }

    /// Builds richtext link facets (UTF-8 byte offsets) so URLs in agent
    /// posts render as clickable links, matching the plugin's composer.
    /// Internal (not private) so tests can verify byte-offset math directly.
    static func detectBlueskyLinkFacets(in text: String) -> [[String: Any]] {
        var facets: [[String: Any]] = []
        let pattern = #"https?://[^\s)>\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            let urlString = nsText.substring(with: match.range)
            let prefix = nsText.substring(with: NSRange(location: 0, length: match.range.location))
            let byteStart = prefix.utf8.count
            facets.append([
                "index": ["byteStart": byteStart, "byteEnd": byteStart + urlString.utf8.count],
                "features": [["$type": "app.bsky.richtext.facet#link", "uri": urlString]],
            ])
        }
        return facets
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
