import Foundation

// MARK: - OSINT Entity Types

/// A discrete piece of information discovered during an OSINT investigation.
enum OSINTEntityType: String, Codable, CaseIterable, Identifiable, Sendable {
    case name
    case alias
    case account
    case email
    case phone
    case address
    case location
    case organization
    case website
    case image
    case document
    case relationship
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "Name"
        case .alias: return "Alias"
        case .account: return "Account"
        case .email: return "Email"
        case .phone: return "Phone"
        case .address: return "Address"
        case .location: return "Location"
        case .organization: return "Organization"
        case .website: return "Website"
        case .image: return "Image"
        case .document: return "Document"
        case .relationship: return "Relationship"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .name: return "person.text.rectangle"
        case .alias: return "person.crop.rectangle"
        case .account: return "at.circle"
        case .email: return "envelope"
        case .phone: return "phone"
        case .address: return "house"
        case .location: return "mappin.and.ellipse"
        case .organization: return "building.2"
        case .website: return "globe"
        case .image: return "photo"
        case .document: return "doc.text"
        case .relationship: return "person.2"
        case .other: return "questionmark.circle"
        }
    }
}

// MARK: - Verification Status

/// Investigator-controlled confidence in a finding.
/// - `unverified`: freshly discovered, awaiting review.
/// - `accepted`: confirmed by the investigator and used to steer further search.
/// - `rejected`: false positive or irrelevant; ignored by the agent.
/// - `unsure`: possible lead but needs more evidence.
enum OSINTVerificationStatus: String, Codable, CaseIterable, Sendable {
    case unverified
    case accepted
    case rejected
    case unsure

    var displayName: String {
        switch self {
        case .unverified: return "Unverified"
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .unsure: return "Unsure"
        }
    }

    var colorName: String {
        switch self {
        case .unverified: return "yellow"
        case .accepted: return "green"
        case .rejected: return "red"
        case .unsure: return "orange"
        }
    }
}

// MARK: - Profile Finding

/// One finding in an OSINT subject profile.
struct OSINTProfileFinding: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    /// What kind of information this is.
    var entityType: OSINTEntityType
    /// The actual value (username, email, address line, URL, etc.).
    var value: String
    /// Human-readable label or context, e.g. "Instagram — professional account".
    var label: String?
    /// Where this was found.
    var source: String
    /// Direct URL to the source, when available.
    var sourceURL: String?
    /// Model-estimated confidence before investigator review.
    var confidence: OSINTConfidence
    /// Investigator review status.
    var verificationStatus: OSINTVerificationStatus
    /// Free-form notes from the agent or investigator.
    var notes: String?
    /// When the finding was recorded.
    var timestamp: Date
    /// IDs of related findings (e.g. an account linked to an email).
    var relatedFindingIDs: [UUID]

    init(
        id: UUID = UUID(),
        entityType: OSINTEntityType,
        value: String,
        label: String? = nil,
        source: String,
        sourceURL: String? = nil,
        confidence: OSINTConfidence = .medium,
        verificationStatus: OSINTVerificationStatus = .unverified,
        notes: String? = nil,
        timestamp: Date = Date(),
        relatedFindingIDs: [UUID] = []
    ) {
        self.id = id
        self.entityType = entityType
        self.value = value
        self.label = label
        self.source = source
        self.sourceURL = sourceURL
        self.confidence = confidence
        self.verificationStatus = verificationStatus
        self.notes = notes
        self.timestamp = timestamp
        self.relatedFindingIDs = relatedFindingIDs
    }
}

// MARK: - Confidence

enum OSINTConfidence: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low

    var displayName: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        }
    }
}

// MARK: - Profile

/// A collection of findings about one OSINT subject. Multiple profiles can be
/// stored per agent; one is designated as the "active" profile that receives
/// new findings and is injected into the agent's system prompt.
struct OSINTProfile: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    /// Optional subject name — the agent can set this when it identifies the target.
    var subjectName: String?
    var findings: [OSINTProfileFinding]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), subjectName: String? = nil, findings: [OSINTProfileFinding] = []) {
        self.id = id
        self.subjectName = subjectName
        self.findings = findings
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - Per-agent profile container

/// Persistence wrapper for all profiles belonging to one agent, plus the active
/// profile id. This replaces the previous single-profile-per-agent file format.
struct OSINTProfileAgentContainer: Codable, Sendable {
    var profiles: [OSINTProfile]
    var activeProfileID: UUID?
}
