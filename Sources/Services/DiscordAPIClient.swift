import Foundation

/// Low-level Discord REST API client using `URLSession`. Handles bot-token
/// authorization, JSON decoding, and basic rate-limit backoff.
actor DiscordAPIClient {
    private let token: String
    private let baseURL = URL(string: "https://discord.com/api/v10")!
    private let decoder: JSONDecoder

    init(token: String) {
        self.token = token
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        // Discord timestamps include fractional seconds; `.iso8601` handles
        // them on modern Foundation, but the `withFractionalSeconds` option is
        // the explicit fallback.
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
            }
            return date
        }
    }

    // MARK: - Guilds

    func getCurrentGuilds() async throws -> [DiscordGuild] {
        try await get(path: "/users/@me/guilds")
    }

    func getGuild(id: String) async throws -> DiscordGuild {
        try await get(path: "/guilds/\(id)")
    }

    func getGuildChannels(id: String) async throws -> [DiscordChannel] {
        try await get(path: "/guilds/\(id)/channels")
    }

    func getGuildRoles(id: String) async throws -> [DiscordRole] {
        try await get(path: "/guilds/\(id)/roles")
    }

    // MARK: - Channels

    func getMessages(channelID: String, limit: Int = 100, before: String? = nil) async throws -> [DiscordMessage] {
        var components = URLComponents()
        components.path = "/channels/\(channelID)/messages"
        var query = [URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        components.queryItems = query
        return try await get(path: components.string!)
    }

    // MARK: - Generic request

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DiscordAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let rateLimit = DiscordRateLimitInfo.parse(from: response)
        await applyRateLimit(rateLimit)

        guard let http = response as? HTTPURLResponse else {
            throw DiscordAPIError.noResponse
        }
        if http.statusCode == 429 {
            throw DiscordAPIError.rateLimited(retryAfter: rateLimit.retryAfter ?? 1)
        }
        if http.statusCode == 401 {
            throw DiscordAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DiscordAPIError.httpError(status: http.statusCode, body: body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw DiscordAPIError.decoding(description: error.localizedDescription, data: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func applyRateLimit(_ info: DiscordRateLimitInfo) async {
        // If Discord explicitly told us to retry after a 429, callers handle it.
        // Otherwise, if we're running low on remaining calls, pause briefly to
        // avoid hammering the API.
        if let remaining = info.remaining, remaining < 2, let resetAfter = info.resetAfter, resetAfter > 0 {
            let delay = resetAfter + 0.05
            try? await Task.sleep(for: .seconds(delay))
        } else if let remaining = info.remaining, remaining < 2 {
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

enum DiscordAPIError: LocalizedError, Sendable {
    case invalidURL
    case noResponse
    case unauthorized
    case rateLimited(retryAfter: Double)
    case httpError(status: Int, body: String)
    case decoding(description: String, data: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Discord API URL"
        case .noResponse: return "No HTTP response from Discord"
        case .unauthorized: return "Discord bot token is invalid or unauthorized"
        case .rateLimited(let retryAfter): return "Discord rate limited. Retry after \(retryAfter)s"
        case .httpError(let status, let body): return "Discord HTTP error \(status): \(body)"
        case .decoding(let description, let data): return "Discord response decoding failed: \(description)\n\(data)"
        }
    }
}
