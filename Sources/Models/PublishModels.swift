import Foundation

// MARK: - Publish status

enum PublishStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft = "draft"
    case inReview = "inReview"
    case scheduled = "scheduled"
    case published = "published"
    case archived = "archived"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .draft: return String(localized: "Draft")
        case .inReview: return String(localized: "In Review")
        case .scheduled: return String(localized: "Scheduled")
        case .published: return String(localized: "Published")
        case .archived: return String(localized: "Archived")
        }
    }

    var kanbanColumnColor: KanbanColumnColor {
        switch self {
        case .draft: return .gray
        case .inReview: return .yellow
        case .scheduled: return .blue
        case .published: return .green
        case .archived: return .purple
        }
    }

    /// Derives status from the current tag registry.
    /// Precedence: published > publish (scheduled) > review (inReview) > draft.
    static func derived(from tagNames: Set<String>, registry: [PublishTag]) -> PublishStatus {
        let normalized = Set(tagNames.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        let activeRoles = Set(registry.compactMap { tag -> PublishTagRole? in
            guard normalized.contains(tag.name) else { return nil }
            return tag.role
        })
        if activeRoles.contains(.published) { return .published }
        if activeRoles.contains(.publish) { return .scheduled }
        if activeRoles.contains(.review) { return .inReview }
        return .draft
    }

    /// Legacy hard-coded fallback used when no registry is available.
    static func derived(from tags: Set<String>) -> PublishStatus {
        let normalized = Set(tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        if normalized.contains("published") { return .published }
        if normalized.contains("publish") { return .scheduled }
        if normalized.contains("review") { return .inReview }
        return .draft
    }
}

// MARK: - Source kind

enum PublishSourceKind: String, Codable, Sendable, CaseIterable {
    case notesMD = "notesMD"
    case appleNotes = "appleNotes"
    case maestroDocs = "maestroDocs"
    case swiftWeaver = "swiftWeaver"
    case maestroDB = "maestroDB"
    case dam = "dam"
    case knowledge = "knowledge"
    case chat = "chat"
    case plan = "plan"
    case manual = "manual"

    var displayName: String {
        switch self {
        case .notesMD: return String(localized: "Notes.md")
        case .appleNotes: return String(localized: "Apple Notes")
        case .maestroDocs: return String(localized: "MaestroDocs")
        case .swiftWeaver: return String(localized: "SwiftWeaver")
        case .maestroDB: return String(localized: "MaestroDB")
        case .dam: return String(localized: "MaestroDAM")
        case .knowledge: return String(localized: "Knowledge")
        case .chat: return String(localized: "Chat")
        case .plan: return String(localized: "Plan")
        case .manual: return String(localized: "Manual")
        }
    }

    var icon: String {
        switch self {
        case .notesMD: return "doc.text"
        case .appleNotes: return "note.text"
        case .maestroDocs: return "doc.richtext"
        case .swiftWeaver: return "rectangle.dashed"
        case .maestroDB: return "tablecells"
        case .dam: return "photo.on.rectangle.angled"
        case .knowledge: return "brain"
        case .chat: return "bubble.left.and.bubble.right"
        case .plan: return "list.bullet.rectangle"
        case .manual: return "plus.square"
        }
    }
}

// MARK: - Publish tag role

/// The publishing workflow role a tag plays. System tags have fixed roles;
/// custom tags are role-less and only trigger inclusion, not status promotion.
enum PublishTagRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft
    case publish
    case published
    case review

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .draft: return String(localized: "Draft")
        case .publish: return String(localized: "Publish / Scheduled")
        case .published: return String(localized: "Published")
        case .review: return String(localized: "In Review")
        }
    }
}

// MARK: - Publish tag

struct PublishTag: Identifiable, Codable, Sendable, Equatable {
    var id: String { name.lowercased() }
    var name: String
    var isSystem: Bool
    var role: PublishTagRole?
    var color: KanbanColumnColor?

    init(
        name: String,
        isSystem: Bool = false,
        role: PublishTagRole? = nil,
        color: KanbanColumnColor? = nil
    ) {
        self.name = name.lowercased().trimmingCharacters(in: .whitespaces)
        self.isSystem = isSystem
        self.role = role
        self.color = color
    }
}

// MARK: - Publish draft

/// A snapshot of a piece of content the Publish app is tracking.
struct PublishDraft: Identifiable, Codable, Sendable, Equatable {
    /// Stable identity derived from the source path so rescans merge instead of duplicate.
    var id: String { sourcePath }

    var sourceKind: PublishSourceKind
    var sourcePath: String
    var title: String
    var summary: String
    var bodyMarkdown: String
    var bodyHTML: String
    var tags: [String]
    var status: PublishStatus
    var createdAt: Date
    var modifiedAt: Date
    var publishedAt: Date?
    var feedID: UUID?
    var assetPaths: [String]
    /// Paths to related drafts or assets in other SwiftMaestro apps (e.g. a MaestroDocs file or SwiftWeaver HTML).
    var linkedSourcePaths: [String]

    init(
        sourceKind: PublishSourceKind,
        sourcePath: String,
        title: String,
        summary: String = "",
        bodyMarkdown: String = "",
        bodyHTML: String = "",
        tags: [String] = [],
        status: PublishStatus = .draft,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        publishedAt: Date? = nil,
        feedID: UUID? = nil,
        assetPaths: [String] = [],
        linkedSourcePaths: [String] = []
    ) {
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.title = title
        self.summary = summary
        self.bodyMarkdown = bodyMarkdown
        self.bodyHTML = bodyHTML
        self.tags = tags.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        self.status = status
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.publishedAt = publishedAt
        self.feedID = feedID
        self.assetPaths = assetPaths
        self.linkedSourcePaths = linkedSourcePaths
    }
}

// MARK: - Publish feed

struct PublishFeed: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    /// Absolute path to a directory where the feed file should be written.
    /// When nil, the default `Documents/SwiftMaestro Feeds` directory is used.
    var outputDirectory: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        outputDirectory: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.outputDirectory = outputDirectory
        self.createdAt = createdAt
    }
}

// MARK: - Neocities destination

struct NeocitiesConfig: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var sitename: String
    /// Name of a secret in SecretsStore that holds the Neocities API key.
    var apiKeySecretName: String
    /// Optional remote path prefix (e.g. "posts/"). Stored without leading slash.
    var basePath: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sitename: String,
        apiKeySecretName: String,
        basePath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sitename = sitename
        self.apiKeySecretName = apiKeySecretName
        self.basePath = basePath?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.createdAt = createdAt
    }

    /// Remote path for a given filename, applying the base path.
    func remotePath(for filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let basePath, !basePath.isEmpty {
            return "\(basePath)/\(trimmed)"
        }
        return trimmed
    }
}

// MARK: - Publish history

struct PublishHistoryEntry: Identifiable, Codable, Sendable {
    var id: UUID
    var draftID: String
    var title: String
    var feedID: UUID?
    var feedName: String
    var outputPath: String
    var publishedAt: Date

    init(
        id: UUID = UUID(),
        draftID: String,
        title: String,
        feedID: UUID? = nil,
        feedName: String,
        outputPath: String,
        publishedAt: Date = Date()
    ) {
        self.id = id
        self.draftID = draftID
        self.title = title
        self.feedID = feedID
        self.feedName = feedName
        self.outputPath = outputPath
        self.publishedAt = publishedAt
    }
}

// MARK: - Social cross-posting

/// Supported social platforms for one-click cross-posting from Publish.
enum SocialPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case bluesky
    case mastodon
    case patreon
    case facebook
    case instagram
    case threads
    case twitter
    case linkedin
    case tumblr
    case youtube
    case vimeo
    case dailymotion
    case peertube
    case tiktok
    case vk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bluesky: return String(localized: "Bluesky")
        case .mastodon: return String(localized: "Mastodon")
        case .patreon: return String(localized: "Patreon")
        case .facebook: return String(localized: "Facebook")
        case .instagram: return String(localized: "Instagram")
        case .threads: return String(localized: "Threads")
        case .twitter: return String(localized: "Twitter / X")
        case .linkedin: return String(localized: "LinkedIn")
        case .tumblr: return String(localized: "Tumblr")
        case .youtube: return String(localized: "YouTube")
        case .vimeo: return String(localized: "Vimeo")
        case .dailymotion: return String(localized: "Dailymotion")
        case .peertube: return String(localized: "PeerTube")
        case .tiktok: return String(localized: "TikTok")
        case .vk: return String(localized: "VK Video")
        }
    }

    var icon: String {
        switch self {
        case .bluesky: return "at"
        case .mastodon: return "bubble.left.and.text.bubble.right"
        case .patreon: return "heart.circle"
        case .facebook: return "f.circle"
        case .instagram: return "camera.circle"
        case .threads: return "text.bubble"
        case .twitter: return "x.circle"
        case .linkedin: return "person.line.dotted.person"
        case .tumblr: return "t.circle"
        case .youtube: return "play.rectangle"
        case .vimeo: return "play.circle"
        case .dailymotion: return "play.square"
        case .peertube: return "network"
        case .tiktok: return "music.note"
        case .vk: return "film"
        }
    }

    /// Maximum length for a single post on this platform.
    var characterLimit: Int {
        switch self {
        case .bluesky: return 300
        case .mastodon, .threads: return 500
        case .twitter: return 280
        case .linkedin: return 3000
        case .facebook: return 63206
        case .instagram: return 2200
        case .patreon, .tumblr, .youtube, .vimeo, .dailymotion, .peertube, .tiktok, .vk:
            return 0
        }
    }

    /// Whether the platform currently supports creating posts through the API.
    var supportsPosting: Bool {
        switch self {
        case .bluesky, .mastodon, .facebook, .instagram, .threads, .twitter, .linkedin, .youtube, .vimeo, .dailymotion, .peertube, .tiktok, .vk:
            return true
        case .patreon, .tumblr:
            return false
        }
    }

    /// A short hint shown in the UI for what account identifier this platform needs.
    var accountIdentifierHint: String {
        switch self {
        case .bluesky, .patreon, .tumblr:
            return ""
        case .mastodon:
            return "Instance URL (e.g. mastodon.social)"
        case .facebook:
            return "Page ID"
        case .instagram:
            return "Instagram Business Account ID"
        case .threads:
            return "Threads User ID"
        case .twitter:
            return "Twitter username (for display only)"
        case .linkedin:
            return "Author URN (e.g. urn:li:person:123)"
        case .youtube:
            return "YouTube channel ID (optional)"
        case .vimeo:
            return "Vimeo user ID (optional)"
        case .dailymotion:
            return "Dailymotion profile ID (optional)"
        case .peertube:
            return "PeerTube instance URL (e.g. https://peertube.tv)"
        case .tiktok:
            return "TikTok open ID (optional)"
        case .vk:
            return "VK group ID (optional, for group uploads)"
        }
    }
}

/// A configured social-media account that Publish can cross-post to.
struct SocialDestinationConfig: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var platform: SocialPlatform
    /// User-facing label, e.g. "@alice on mastodon.social".
    var label: String
    /// Keychain account name that holds the access token.
    /// For Mastodon this is typically `plugin.mastodon.accessToken`.
    /// For Bluesky the tokens are read from the plugin's fixed keychain keys,
    /// so this field is ignored.
    var secretName: String
    /// Mastodon instance URL (e.g. `https://mastodon.social`). Unused for Bluesky.
    var serverURL: String?
    /// Platform-specific account identifier (page ID, user ID, URN, etc.).
    var accountIdentifier: String?
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        platform: SocialPlatform,
        label: String,
        secretName: String = "",
        serverURL: String? = nil,
        accountIdentifier: String? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.platform = platform
        self.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secretName = secretName.trimmingCharacters(in: .whitespaces)
        self.serverURL = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountIdentifier = accountIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    var normalizedServerURL: String? {
        guard let serverURL, !serverURL.isEmpty else { return nil }
        var url = serverURL
        if !url.lowercased().hasPrefix("http://"), !url.lowercased().hasPrefix("https://") {
            url = "https://" + url
        }
        return url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Result of a single cross-post attempt.
struct CrossPostResult: Codable, Sendable, Identifiable {
    var id: UUID
    var destinationID: UUID
    var platform: SocialPlatform
    var label: String
    var success: Bool
    var message: String
    var postedURL: String?
    var timestamp: Date

    init(
        destinationID: UUID,
        platform: SocialPlatform,
        label: String,
        success: Bool,
        message: String,
        postedURL: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = UUID()
        self.destinationID = destinationID
        self.platform = platform
        self.label = label
        self.success = success
        self.message = message
        self.postedURL = postedURL
        self.timestamp = timestamp
    }
}

/// A history record for social cross-posts.
struct SocialPostHistoryEntry: Identifiable, Codable, Sendable {
    var id: UUID
    var draftID: String
    var draftTitle: String
    var destinationID: UUID
    var platform: SocialPlatform
    var label: String
    var success: Bool
    var message: String
    var postedURL: String?
    var publishedAt: Date

    init(
        id: UUID = UUID(),
        draftID: String,
        draftTitle: String,
        destinationID: UUID,
        platform: SocialPlatform,
        label: String,
        success: Bool,
        message: String,
        postedURL: String? = nil,
        publishedAt: Date = Date()
    ) {
        self.id = id
        self.draftID = draftID
        self.draftTitle = draftTitle
        self.destinationID = destinationID
        self.platform = platform
        self.label = label
        self.success = success
        self.message = message
        self.postedURL = postedURL
        self.publishedAt = publishedAt
    }
}
