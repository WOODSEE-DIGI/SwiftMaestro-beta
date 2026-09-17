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
