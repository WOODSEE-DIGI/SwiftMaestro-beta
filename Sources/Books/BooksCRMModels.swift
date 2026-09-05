import Foundation
import GRDB

// MARK: - CRM Lead

/// A sales lead: a potential customer before they become a BooksClient.
struct BooksCRMLead: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var name: String
    var company: String?
    var email: String?
    var phone: String?
    /// ABN/VAT/EIN etc.
    var taxNumber: String?
    var country: String?
    var status: LeadStatus
    var source: String?
    var estimatedValue: Double?
    var currency: String
    var assignedTo: String?
    var notes: String?
    /// If converted, the resulting client ID.
    var convertedClientID: Int64?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "crm_leads"

    enum CodingKeys: String, CodingKey {
        case id, name, company, email, phone, source, notes
        case taxNumber = "tax_number"
        case country
        case status
        case estimatedValue = "estimated_value"
        case currency
        case assignedTo = "assigned_to"
        case convertedClientID = "converted_client_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let status = Column(CodingKeys.status)
        static let name = Column(CodingKeys.name)
    }

    enum LeadStatus: String, Codable, CaseIterable, Sendable {
        case new = "NEW"
        case contacted = "CONTACTED"
        case qualified = "QUALIFIED"
        case unqualified = "UNQUALIFIED"
        case converted = "CONVERTED"

        var displayName: String {
            switch self {
            case .new: return "New"
            case .contacted: return "Contacted"
            case .qualified: return "Qualified"
            case .unqualified: return "Unqualified"
            case .converted: return "Converted"
            }
        }
    }

    static var blank: BooksCRMLead {
        BooksCRMLead(
            id: nil, name: "", company: nil, email: nil, phone: nil,
            taxNumber: nil, country: LocaleSettings.shared.country,
            status: .new, source: nil, estimatedValue: nil,
            currency: LocaleSettings.shared.defaultCurrency,
            assignedTo: nil, notes: nil, convertedClientID: nil,
            createdAt: Date(), updatedAt: Date())
    }
}

// MARK: - CRM Opportunity

/// A sales opportunity tied to either a lead or an existing client.
struct BooksCRMOpportunity: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var title: String
    /// Either lead_id or client_id is set; lead takes precedence.
    var leadID: Int64?
    var clientID: Int64?
    var stage: OpportunityStage
    var value: Double?
    var currency: String
    var probability: Int
    var expectedCloseDate: Date?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "crm_opportunities"

    enum CodingKeys: String, CodingKey {
        case id, title, value, currency, probability, notes
        case leadID = "lead_id"
        case clientID = "client_id"
        case stage
        case expectedCloseDate = "expected_close_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns {
        static let stage = Column(CodingKeys.stage)
        static let expectedCloseDate = Column(CodingKeys.expectedCloseDate)
    }

    enum OpportunityStage: String, Codable, CaseIterable, Sendable {
        case lead = "LEAD"
        case qualified = "QUALIFIED"
        case proposal = "PROPOSAL"
        case negotiation = "NEGOTIATION"
        case closedWon = "CLOSED_WON"
        case closedLost = "CLOSED_LOST"

        var displayName: String {
            switch self {
            case .lead: return "Lead"
            case .qualified: return "Qualified"
            case .proposal: return "Proposal"
            case .negotiation: return "Negotiation"
            case .closedWon: return "Closed Won"
            case .closedLost: return "Closed Lost"
            }
        }

        var order: Int {
            switch self {
            case .lead: return 0
            case .qualified: return 1
            case .proposal: return 2
            case .negotiation: return 3
            case .closedWon: return 4
            case .closedLost: return 4
            }
        }
    }

    static var blank: BooksCRMOpportunity {
        BooksCRMOpportunity(
            id: nil, title: "", leadID: nil, clientID: nil,
            stage: .lead, value: nil,
            currency: LocaleSettings.shared.defaultCurrency,
            probability: 20, expectedCloseDate: nil, notes: nil,
            createdAt: Date(), updatedAt: Date())
    }
}

// MARK: - CRM Activity

/// A call, email, meeting, note, or task attached to a lead or client.
struct BooksCRMActivity: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    var id: Int64?
    var kind: Kind
    /// "lead" or "client"
    var contactKind: String
    var contactID: Int64
    var subject: String
    var notes: String?
    var dueDate: Date?
    var completedDate: Date?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "crm_activities"

    enum CodingKeys: String, CodingKey {
        case id, kind, subject, notes
        case contactKind = "contact_kind"
        case contactID = "contact_id"
        case dueDate = "due_date"
        case completedDate = "completed_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Kind: String, Codable, CaseIterable, Sendable {
        case call, email, meeting, note, task

        var icon: String {
            switch self {
            case .call: return "phone"
            case .email: return "envelope"
            case .meeting: return "person.2"
            case .note: return "note.text"
            case .task: return "checkmark.square"
            }
        }
    }

    static var blank: BooksCRMActivity {
        BooksCRMActivity(
            id: nil, kind: .note, contactKind: "lead", contactID: 0,
            subject: "", notes: nil, dueDate: nil, completedDate: nil,
            createdAt: Date(), updatedAt: Date())
    }
}
