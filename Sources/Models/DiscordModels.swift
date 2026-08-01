import Foundation

// MARK: - Discord API models

struct DiscordGuild: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let icon: String?
    let ownerID: String?

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case ownerID = "owner_id"
    }
}

struct DiscordChannel: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String?
    let type: Int
    let parentID: String?
    let position: Int?
    let topic: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, position, topic
        case parentID = "parent_id"
    }

    var isText: Bool { [0, 5, 10, 11, 12].contains(type) }
    var isCategory: Bool { type == 4 }
    var isVoice: Bool { type == 2 }
    var displayName: String { name ?? "(unknown)" }
}

struct DiscordRole: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let color: Int
    let permissions: String
    let position: Int
    let hoist: Bool
    let mentionable: Bool
}

struct DiscordUser: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let username: String
    let globalName: String?
    let avatar: String?
    let bot: Bool?

    var displayName: String { globalName?.isEmpty == false ? globalName! : username }
}

struct DiscordMessage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let channelID: String
    let author: DiscordUser
    let content: String
    let timestamp: Date
    let editedTimestamp: Date?
    let attachments: [DiscordAttachment]
    let embeds: [DiscordEmbed]
    let reactions: [DiscordReaction]?
    let type: Int

    enum CodingKeys: String, CodingKey {
        case id, author, content, timestamp, attachments, embeds, reactions, type
        case channelID = "channel_id"
        case editedTimestamp = "edited_timestamp"
    }
}

struct DiscordAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let filename: String
    let url: String
    let proxyURL: String
    let size: Int
    let contentType: String?
    let width: Int?
    let height: Int?

    enum CodingKeys: String, CodingKey {
        case id, filename, url, size, width, height
        case proxyURL = "proxy_url"
        case contentType = "content_type"
    }

    var isImage: Bool {
        guard let contentType else { return false }
        return contentType.hasPrefix("image/")
    }
}

struct DiscordEmbed: Codable, Hashable, Sendable {
    let title: String?
    let description: String?
    let url: String?
    let color: Int?
}

struct DiscordReaction: Codable, Hashable, Sendable {
    let count: Int
    let emoji: DiscordEmoji
    let me: Bool
}

struct DiscordEmoji: Codable, Hashable, Sendable {
    let id: String?
    let name: String?

    var isCustom: Bool { id != nil && !(id?.isEmpty ?? true) }
    var imageURL: URL? {
        guard isCustom, let id else { return nil }
        return URL(string: "https://cdn.discordapp.com/emojis/\(id).png?size=32")
    }
}

struct DiscordRateLimitInfo: Sendable {
    let remaining: Int?
    let resetAfter: Double?
    let retryAfter: Double?
    let limit: Int?
}

extension DiscordRateLimitInfo {
    static func parse(from response: URLResponse) -> DiscordRateLimitInfo {
        guard let http = response as? HTTPURLResponse else { return DiscordRateLimitInfo(remaining: nil, resetAfter: nil, retryAfter: nil, limit: nil) }
        let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let limit = http.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init)
        let resetAfter = http.value(forHTTPHeaderField: "X-RateLimit-Reset-After").flatMap(Double.init)
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        return DiscordRateLimitInfo(remaining: remaining, resetAfter: resetAfter, retryAfter: retryAfter, limit: limit)
    }
}
