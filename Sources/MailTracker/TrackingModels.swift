import Foundation

public enum TrackingMode: String, Codable, Sendable {
    case disabled
    case opensOnly
    case opensAndClicks
}

public enum TrackingEventType: String, Codable, Sendable {
    case sent
    case open
    case click
    case reply
}

public enum OpenSignalQuality: String, Codable, Sendable {
    case likelyHuman
    case likelyProxy
    case unknown
    case historicalImported
}

public struct TrackingHeaderEnvelope: Codable, Sendable {
    public let messageID: String
    public let sender: String
    public let recipients: [String]
    public let mode: TrackingMode
    public let createdAt: Date
    public let metadata: [String: String]

    public init(
        messageID: String,
        sender: String,
        recipients: [String],
        mode: TrackingMode,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.messageID = messageID
        self.sender = sender
        self.recipients = recipients
        self.mode = mode
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct MessageTrackingSummary: Codable, Sendable {
    public let messageID: String
    public let subject: String?
    public let sender: String?
    public let recipients: [String]
    public let mode: TrackingMode?
    public let totalEvents: Int
    public let sentCount: Int
    public let openCount: Int
    public let clickCount: Int
    public let replyCount: Int
    public let uniqueOpenRecipients: Int
    public let uniqueClickRecipients: Int
    public let firstSentAt: Date?
    public let firstOpenedAt: Date?
    public let lastOpenedAt: Date?
    public let firstClickedAt: Date?
    public let lastClickedAt: Date?
    public let firstRepliedAt: Date?
    public let lastEventAt: Date?
    public let openQualityCounts: [String: Int]

    public init(
        messageID: String,
        subject: String?,
        sender: String?,
        recipients: [String],
        mode: TrackingMode?,
        totalEvents: Int,
        sentCount: Int,
        openCount: Int,
        clickCount: Int,
        replyCount: Int,
        uniqueOpenRecipients: Int,
        uniqueClickRecipients: Int,
        firstSentAt: Date?,
        firstOpenedAt: Date?,
        lastOpenedAt: Date?,
        firstClickedAt: Date?,
        lastClickedAt: Date?,
        firstRepliedAt: Date?,
        lastEventAt: Date?,
        openQualityCounts: [String: Int]
    ) {
        self.messageID = messageID
        self.subject = subject
        self.sender = sender
        self.recipients = recipients
        self.mode = mode
        self.totalEvents = totalEvents
        self.sentCount = sentCount
        self.openCount = openCount
        self.clickCount = clickCount
        self.replyCount = replyCount
        self.uniqueOpenRecipients = uniqueOpenRecipients
        self.uniqueClickRecipients = uniqueClickRecipients
        self.firstSentAt = firstSentAt
        self.firstOpenedAt = firstOpenedAt
        self.lastOpenedAt = lastOpenedAt
        self.firstClickedAt = firstClickedAt
        self.lastClickedAt = lastClickedAt
        self.firstRepliedAt = firstRepliedAt
        self.lastEventAt = lastEventAt
        self.openQualityCounts = openQualityCounts
    }
}

public struct MessageSummaryResponse: Codable, Sendable {
    public let summary: MessageTrackingSummary

    public init(summary: MessageTrackingSummary) {
        self.summary = summary
    }
}

public struct ComposeTrackingInput: Sendable {
    public let messageID: String
    public let sender: String
    public let recipients: [String]
    public let mode: TrackingMode
    public let subject: String?
    public let metadata: [String: String]

    public init(
        messageID: String,
        sender: String,
        recipients: [String],
        mode: TrackingMode = .opensAndClicks,
        subject: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.messageID = messageID
        self.sender = sender
        self.recipients = recipients
        self.mode = mode
        self.subject = subject
        self.metadata = metadata
    }
}

public struct TrackedMessageRecord: Codable, Sendable {
    public let messageID: String
    public let sender: String
    public let recipients: [String]
    public let subject: String?
    public let mode: TrackingMode
    public let createdAt: Date
    public let metadata: [String: String]

    public init(
        messageID: String,
        sender: String,
        recipients: [String],
        subject: String?,
        mode: TrackingMode,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.messageID = messageID
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.mode = mode
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public struct TrackingEvent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let messageID: String
    public let type: TrackingEventType
    public let timestamp: Date
    public let recipient: String?
    public let sourceIP: String?
    public let userAgent: String?
    public let attributes: [String: String]

    public init(
        id: UUID = UUID(),
        messageID: String,
        type: TrackingEventType,
        timestamp: Date = Date(),
        recipient: String? = nil,
        sourceIP: String? = nil,
        userAgent: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.id = id
        self.messageID = messageID
        self.type = type
        self.timestamp = timestamp
        self.recipient = recipient
        self.sourceIP = sourceIP
        self.userAgent = userAgent
        self.attributes = attributes
    }
}

public struct RegisterMessageRequest: Codable, Sendable {
    public let messageID: String?
    public let sender: String
    public let recipients: [String]
    public let subject: String?
    public let trackingMode: TrackingMode
    public let metadata: [String: String]

    public init(
        messageID: String? = nil,
        sender: String,
        recipients: [String],
        subject: String? = nil,
        trackingMode: TrackingMode = .opensAndClicks,
        metadata: [String: String] = [:]
    ) {
        self.messageID = messageID
        self.sender = sender
        self.recipients = recipients
        self.subject = subject
        self.trackingMode = trackingMode
        self.metadata = metadata
    }
}

public struct RegisterMessageResponse: Codable, Sendable {
    public let messageID: String
    public let pixelTemplateURL: String
    public let clickTemplateURL: String

    public init(messageID: String, pixelTemplateURL: String, clickTemplateURL: String) {
        self.messageID = messageID
        self.pixelTemplateURL = pixelTemplateURL
        self.clickTemplateURL = clickTemplateURL
    }
}

public struct EventListResponse: Codable, Sendable {
    public let events: [TrackingEvent]

    public init(events: [TrackingEvent]) {
        self.events = events
    }
}

public struct RewriteMessageRequest: Codable, Sendable {
    public let rawMessageBase64: String
    public let recipient: String?

    public init(rawMessageBase64: String, recipient: String? = nil) {
        self.rawMessageBase64 = rawMessageBase64
        self.recipient = recipient
    }
}

public struct RewriteMessageResponse: Codable, Sendable {
    public let messageID: String
    public let recipient: String?
    public let trackingApplied: Bool
    public let rewrittenLinkCount: Int
    public let openPixelURL: String?
    public let rewrittenMessageBase64: String
    public let notes: [String]

    public init(
        messageID: String,
        recipient: String?,
        trackingApplied: Bool,
        rewrittenLinkCount: Int,
        openPixelURL: String?,
        rewrittenMessageBase64: String,
        notes: [String] = []
    ) {
        self.messageID = messageID
        self.recipient = recipient
        self.trackingApplied = trackingApplied
        self.rewrittenLinkCount = rewrittenLinkCount
        self.openPixelURL = openPixelURL
        self.rewrittenMessageBase64 = rewrittenMessageBase64
        self.notes = notes
    }
}

public struct TrackingTokenPayload: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case open
        case click
    }

    public let messageID: String
    public let recipient: String?
    public let kind: Kind
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(
        messageID: String,
        recipient: String?,
        kind: Kind,
        issuedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.messageID = messageID
        self.recipient = recipient
        self.kind = kind
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public enum TrackingHeaderNames {
    public static let messageID = "x-owntrack-message-id"
    public static let envelope = "x-owntrack-envelope"
    public static let signature = "x-owntrack-signature"
    public static let relayBaseURL = "x-owntrack-relay-base-url"
}
