import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native tools for additional social platforms
//
// These tools read OAuth access tokens from the Keychain (by secret name) so
// the user can cross-post from Publish to Facebook Pages, Threads, Twitter/X,
// LinkedIn, and Instagram. Tokens must be obtained outside the app and stored
// in the Keychain (Settings → Secrets or the `security` CLI).

extension MaestroTools {

    static func registerSocialPlatformTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "post_facebook_page",
                spec: socialPlatformToolSpecs[0],
                category: ToolCategory.facebook.rawValue,
                handler: { call in await postFacebookPage(call) }),
            ToolDefinition(
                name: "post_threads",
                spec: socialPlatformToolSpecs[1],
                category: ToolCategory.threads.rawValue,
                handler: { call in await postThreads(call) }),
            ToolDefinition(
                name: "post_twitter",
                spec: socialPlatformToolSpecs[2],
                category: ToolCategory.twitter.rawValue,
                handler: { call in await postTwitter(call) }),
            ToolDefinition(
                name: "post_linkedin",
                spec: socialPlatformToolSpecs[3],
                category: ToolCategory.linkedin.rawValue,
                handler: { call in await postLinkedIn(call) }),
            ToolDefinition(
                name: "post_instagram",
                spec: socialPlatformToolSpecs[4],
                category: ToolCategory.instagram.rawValue,
                handler: { call in await postInstagram(call) }),
        ])
    }

    static var socialPlatformToolSpecs: [ToolSpec] {
        [
            rawSpec("post_facebook_page",
                "Create a text post on a Facebook Page using the Graph API.",
                properties: [
                    "text": ["type": "string", "description": "Post message."],
                    "page_id": ["type": "string", "description": "Facebook Page ID."],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the Facebook Page access token."],
                ], required: ["text", "page_id", "secret_name"]),
            rawSpec("post_threads",
                "Create a text-only Threads post (max 500 characters).",
                properties: [
                    "text": ["type": "string", "description": "Post text, max 500 characters."],
                    "user_id": ["type": "string", "description": "Threads user ID."],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the Threads Graph API user access token."],
                ], required: ["text", "user_id", "secret_name"]),
            rawSpec("post_twitter",
                "Create a Twitter/X tweet (max 280 characters).",
                properties: [
                    "text": ["type": "string", "description": "Tweet text, max 280 characters."],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the Twitter/X OAuth 2.0 bearer token."],
                ], required: ["text", "secret_name"]),
            rawSpec("post_linkedin",
                "Create a LinkedIn text share.",
                properties: [
                    "text": ["type": "string", "description": "Share text, max 3000 characters."],
                    "author_urn": ["type": "string", "description": "Author URN, e.g. urn:li:person:123 or urn:li:organization:456."],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the LinkedIn OAuth 2.0 access token."],
                ], required: ["text", "author_urn", "secret_name"]),
            rawSpec("post_instagram",
                "Create an Instagram Business/Creator post from a publicly accessible image or video URL.",
                properties: [
                    "caption": ["type": "string", "description": "Caption text, max 2200 characters."],
                    "user_id": ["type": "string", "description": "Instagram Business/Creator account ID."],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the Instagram Graph API access token."],
                    "media_url": ["type": "string", "description": "Publicly accessible HTTPS URL of an image (JPEG/PNG) or video (MP4/MOV)."],
                    "media_type": ["type": "string", "description": "IMAGE, VIDEO, or REELS. Default IMAGE."],
                ], required: ["caption", "user_id", "secret_name", "media_url"]),
        ]
    }

    // MARK: - Args

    private struct PostFacebookPageArgs: Decodable {
        let text: String?
        let page_id: String?
        let secret_name: String?
    }

    private struct PostThreadsArgs: Decodable {
        let text: String?
        let user_id: String?
        let secret_name: String?
    }

    private struct PostTwitterArgs: Decodable {
        let text: String?
        let secret_name: String?
    }

    private struct PostLinkedInArgs: Decodable {
        let text: String?
        let author_urn: String?
        let secret_name: String?
    }

    private struct PostInstagramArgs: Decodable {
        let caption: String?
        let user_id: String?
        let secret_name: String?
        let media_url: String?
        let media_type: String?
    }

    // MARK: - Facebook Page

    private static func postFacebookPage(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PostFacebookPageArgs.self),
              let text = args.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return errorJSON("post_facebook_page requires 'text'") }

        guard let pageID = args.page_id?.trimmingCharacters(in: .whitespaces),
              !pageID.isEmpty else {
            return errorJSON("post_facebook_page requires 'page_id'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("post_facebook_page requires 'secret_name'")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "Facebook")
            let (data, http) = try await socialPOSTQuery(
                url: URL(string: "https://graph.facebook.com/v20.0/\(pageID)/feed")!,
                token: token,
                params: ["message": text]
            )
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Facebook API returned \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            }
            let object = try socialJSON(data) as [String: Any]
            let postID = object["id"] as? String ?? ""
            let postURL = "https://facebook.com/\(postID)"
            return jsonString(["posted": true, "id": postID, "url": postURL])
        } catch {
            return errorJSON("Facebook post failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Threads

    private static func postThreads(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PostThreadsArgs.self),
              let text = args.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return errorJSON("post_threads requires 'text'") }

        guard text.utf8.count <= 500 else {
            return errorJSON("post_threads text is \(text.utf8.count) UTF-8 bytes; the limit is 500")
        }

        guard let userID = args.user_id?.trimmingCharacters(in: .whitespaces),
              !userID.isEmpty else {
            return errorJSON("post_threads requires 'user_id'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("post_threads requires 'secret_name'")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "Threads")
            let base = "https://graph.threads.com/v1.0/\(userID)"

            // Step 1: create media container.
            let (containerData, containerHTTP) = try await socialPOSTQuery(
                url: URL(string: "\(base)/threads")!,
                token: token,
                params: ["media_type": "TEXT", "text": text]
            )
            guard (200..<300).contains(containerHTTP.statusCode) else {
                return errorJSON("Threads container creation failed \(containerHTTP.statusCode): \(String(data: containerData, encoding: .utf8) ?? "")")
            }
            let containerObject = try socialJSON(containerData) as [String: Any]
            guard let creationID = containerObject["id"] as? String, !creationID.isEmpty else {
                return errorJSON("Threads container did not return an id")
            }

            // Step 2: publish container.
            let (publishData, publishHTTP) = try await socialPOSTQuery(
                url: URL(string: "\(base)/threads_publish")!,
                token: token,
                params: ["creation_id": creationID]
            )
            guard (200..<300).contains(publishHTTP.statusCode) else {
                return errorJSON("Threads publish failed \(publishHTTP.statusCode): \(String(data: publishData, encoding: .utf8) ?? "")")
            }
            let publishObject = try socialJSON(publishData) as [String: Any]
            let postID = publishObject["id"] as? String ?? ""
            return jsonString(["posted": true, "id": postID])
        } catch {
            return errorJSON("Threads post failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Twitter / X

    private static func postTwitter(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PostTwitterArgs.self),
              let text = args.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return errorJSON("post_twitter requires 'text'") }

        guard text.count <= 280 else {
            return errorJSON("post_twitter text is \(text.count) characters; the limit is 280")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("post_twitter requires 'secret_name'")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "Twitter/X")
            let url = URL(string: "https://api.twitter.com/2/tweets")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return errorJSON("Non-HTTP response from Twitter/X")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("Twitter/X API returned \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            }
            let object = try socialJSON(data) as [String: Any]
            if let tweetData = object["data"] as? [String: Any],
               let tweetID = tweetData["id"] as? String {
                return jsonString(["posted": true, "id": tweetID, "url": "https://x.com/i/web/status/\(tweetID)"])
            }
            return jsonString(["posted": true])
        } catch {
            return errorJSON("Twitter/X post failed: \(error.localizedDescription)")
        }
    }

    // MARK: - LinkedIn

    private static func postLinkedIn(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PostLinkedInArgs.self),
              let text = args.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return errorJSON("post_linkedin requires 'text'") }

        guard let authorURN = args.author_urn?.trimmingCharacters(in: .whitespaces),
              !authorURN.isEmpty else {
            return errorJSON("post_linkedin requires 'author_urn'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("post_linkedin requires 'secret_name'")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "LinkedIn")
            let url = URL(string: "https://api.linkedin.com/v2/ugcPosts")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
            request.setValue("202505", forHTTPHeaderField: "LinkedIn-Version")
            request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")

            let body: [String: any Sendable] = [
                "author": authorURN,
                "lifecycleState": "PUBLISHED",
                "specificContent": [
                    "com.linkedin.ugc.ShareContent": [
                        "shareCommentary": ["text": text] as [String: any Sendable],
                        "shareMediaCategory": "NONE",
                    ] as [String: any Sendable],
                ] as [String: any Sendable],
                "visibility": [
                    "com.linkedin.ugc.MemberNetworkVisibility": "PUBLIC",
                ] as [String: any Sendable],
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return errorJSON("Non-HTTP response from LinkedIn")
            }
            guard (200..<300).contains(http.statusCode) else {
                return errorJSON("LinkedIn API returned \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
            }
            let postURN = http.allHeaderFields["x-restli-id"] as? String ?? ""
            return jsonString(["posted": true, "urn": postURN])
        } catch {
            return errorJSON("LinkedIn post failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Instagram

    private static func postInstagram(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PostInstagramArgs.self),
              let caption = args.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !caption.isEmpty
        else { return errorJSON("post_instagram requires 'caption'") }

        guard let userID = args.user_id?.trimmingCharacters(in: .whitespaces),
              !userID.isEmpty else {
            return errorJSON("post_instagram requires 'user_id'")
        }
        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("post_instagram requires 'secret_name'")
        }
        guard let mediaURL = args.media_url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mediaURL.isEmpty,
              mediaURL.lowercased().hasPrefix("http://") || mediaURL.lowercased().hasPrefix("https://")
        else {
            return errorJSON("post_instagram requires a public HTTPS 'media_url'")
        }

        let mediaType = (args.media_type ?? "IMAGE").uppercased()
        let validTypes = Set(["IMAGE", "VIDEO", "REELS"])
        guard validTypes.contains(mediaType) else {
            return errorJSON("post_instagram media_type must be IMAGE, VIDEO, or REELS")
        }

        do {
            let token = try requireToken(secretName: secretName, platform: "Instagram")
            let base = "https://graph.facebook.com/v20.0/\(userID)"

            // Step 1: create media container.
            var containerParams: [String: any Sendable] = ["caption": caption]
            if mediaType == "IMAGE" {
                containerParams["image_url"] = mediaURL
            } else {
                containerParams["media_type"] = mediaType
                containerParams["video_url"] = mediaURL
            }

            let (containerData, containerHTTP) = try await socialPOSTQuery(
                url: URL(string: "\(base)/media")!,
                token: token,
                params: containerParams
            )
            guard (200..<300).contains(containerHTTP.statusCode) else {
                return errorJSON("Instagram media container creation failed \(containerHTTP.statusCode): \(String(data: containerData, encoding: .utf8) ?? "")")
            }
            let containerObject = try socialJSON(containerData) as [String: Any]
            guard let creationID = containerObject["id"] as? String, !creationID.isEmpty else {
                return errorJSON("Instagram container did not return an id")
            }

            // Step 2: for video/reels, wait for the container to finish processing.
            if mediaType != "IMAGE" {
                let finished = try await instagramContainerFinished(baseURL: base, creationID: creationID, token: token)
                if !finished {
                    return errorJSON("Instagram video/reel container did not finish processing in time")
                }
            }

            // Step 3: publish container.
            let (publishData, publishHTTP) = try await socialPOSTQuery(
                url: URL(string: "\(base)/media_publish")!,
                token: token,
                params: ["creation_id": creationID]
            )
            guard (200..<300).contains(publishHTTP.statusCode) else {
                return errorJSON("Instagram publish failed \(publishHTTP.statusCode): \(String(data: publishData, encoding: .utf8) ?? "")")
            }
            let publishObject = try socialJSON(publishData) as [String: Any]
            let mediaID = publishObject["id"] as? String ?? ""
            return jsonString(["posted": true, "id": mediaID])
        } catch {
            return errorJSON("Instagram post failed: \(error.localizedDescription)")
        }
    }

    private static func instagramContainerFinished(baseURL: String, creationID: String, token: String) async throws -> Bool {
        let statusURL = URL(string: "\(baseURL)/\(creationID)?fields=status_code&access_token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)")!
        let start = Date()
        while Date().timeIntervalSince(start) < 120 {
            var request = URLRequest(url: statusURL)
            request.timeoutInterval = 30
            request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let object = try? socialJSON(data) as [String: Any],
               let status = object["status_code"] as? String {
                if status == "FINISHED" { return true }
                if status == "ERROR" || status == "EXPIRED" { return false }
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return false
    }

    // MARK: - Shared helpers

    private struct MissingTokenError: LocalizedError {
        let platform: String
        var errorDescription: String? {
            "No access token found for \(platform). Store it in the Keychain and pass the account name as secret_name."
        }
    }

    static func requireToken(secretName: String, platform: String) throws -> String {
        guard let token = try KeychainService.read(account: secretName, allowUI: false),
              !token.isEmpty else {
            throw MissingTokenError(platform: platform)
        }
        return token
    }

    /// POST to a Meta/Threads-style API using query parameters. Required for
    /// Graph endpoints that expect form-style fields on the URL.
    private static func socialPOSTQuery(
        url: URL,
        token: String,
        params: [String: any Sendable]
    ) async throws -> (Data, HTTPURLResponse) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw NSError(domain: "SocialPlatform", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "access_token", value: token))
        for (key, value) in params {
            items.append(URLQueryItem(name: key, value: String(describing: value)))
        }
        components.queryItems = items
        guard let finalURL = components.url else {
            throw NSError(domain: "SocialPlatform", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "SocialPlatform", code: -2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
        }
        return (data, http)
    }

    /// POST to a JSON-based social API using a Bearer token.
    private static func socialPOSTJSON(
        url: URL,
        token: String,
        body: [String: any Sendable]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "SocialPlatform", code: -2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
        }
        return (data, http)
    }

    private static func socialJSON(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "SocialPlatform", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON object"])
        }
        return object
    }
}
