import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native Mastodon tools
//
// Reuses the access token the user saved in the Mastodon plugin panel
// (`plugin.mastodon.accessToken` by default). The instance URL is passed per
// call because the plugin stores it in localStorage, which native Swift cannot
// read, so Publish keeps the instance URL in its own `SocialDestinationConfig`.

extension MaestroTools {

    static func registerMastodonTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "post_mastodon",
                spec: mastodonToolSpecs[0],
                category: ToolCategory.mastodon.rawValue,
                handler: { call in await postMastodon(call) }),
        ])
    }

    static var mastodonToolSpecs: [ToolSpec] {
        [
            rawSpec("post_mastodon",
                "Create a Mastodon post on a configured instance (max 500 characters).",
                properties: [
                    "text": ["type": "string", "description": "Post text, max 500 characters."],
                    "server_url": ["type": "string", "description": "Mastodon instance URL, e.g. https://mastodon.social"],
                    "secret_name": ["type": "string", "description": "Keychain account name holding the access token, typically plugin.mastodon.accessToken."],
                ], required: ["text", "server_url", "secret_name"]),
        ]
    }

    // MARK: - Args

    private struct PostMastodonArgs: Decodable {
        let text: String?
        let server_url: String?
        let secret_name: String?
    }

    private struct MastodonStatusResponse: Decodable {
        let id: String
        let url: String?
        let uri: String?
    }

    // MARK: - Implementation

    private static func postMastodon(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: PostMastodonArgs.self),
              let text = args.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return errorJSON("post_mastodon requires 'text'") }

        guard text.count <= 500 else {
            return errorJSON("post_mastodon text is \(text.count) characters; the limit is 500")
        }

        guard let serverURL = args.server_url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverURL.isEmpty else {
            return errorJSON("post_mastodon requires 'server_url'")
        }

        guard let secretName = args.secret_name?.trimmingCharacters(in: .whitespaces),
              !secretName.isEmpty else {
            return errorJSON("post_mastodon requires 'secret_name'")
        }

        var normalized = serverURL
        if !normalized.lowercased().hasPrefix("http://"),
           !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let accessToken: String
        do {
            guard let token = try KeychainService.read(account: secretName, allowUI: false),
                  !token.isEmpty else {
                return errorJSON("Mastodon access token not found in Keychain for account '\(secretName)'. Sign in via the Mastodon plugin panel first.")
            }
            accessToken = token
        } catch {
            return errorJSON("Failed to read Mastodon access token: \(error.localizedDescription)")
        }

        do {
            let (data, http) = try await mastodonPOST(
                baseURL: normalized,
                path: "/api/v1/statuses",
                token: accessToken,
                body: ["status": text, "visibility": "public"]
            )
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return errorJSON("Mastodon API returned \(http.statusCode): \(body)")
            }
            let status = try JSONDecoder().decode(MastodonStatusResponse.self, from: data)
            return jsonString([
                "posted": true,
                "id": status.id,
                "url": status.url ?? status.uri ?? "",
            ])
        } catch {
            return errorJSON("Mastodon post failed: \(error.localizedDescription)")
        }
    }

    private static func mastodonPOST(
        baseURL: String,
        path: String,
        token: String,
        body: [String: any Sendable]
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: baseURL + path) else {
            throw NSError(domain: "Mastodon", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Mastodon URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SwiftMaestro", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Mastodon", code: -2, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response from Mastodon"])
        }
        return (data, http)
    }
}
