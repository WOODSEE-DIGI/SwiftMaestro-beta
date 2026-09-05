import Foundation

// MARK: - CRM Contact Card Profile

/// A unified CRM contact card profile for a MaestroBooks client or CRM lead.
/// Replaces the older generic ContactCardProfile with a sales/CRM-focused view
/// that also surfaces invoices, assets, and risk flags.
struct CRMContactCardProfile: Identifiable, Sendable {
    let id: String

    /// Display name (company or person).
    var name: String

    /// Optional company name.
    var company: String?

    /// Contact details.
    var email: String?
    var phone: String?
    var taxNumber: String?
    var country: String?

    /// Where this card was opened from.
    var sourceLabel: String

    /// The underlying client, if any.
    var client: BooksClient?

    /// The underlying CRM lead, if any.
    var lead: BooksCRMLead?

    /// Computed risk flag for this contact.
    var riskFlag: RiskFlag?

    /// ABN verification result, if the contact has an ABN and Australia is the country.
    var abnVerification: ABNVerificationResult?

    /// Optional OSINT Industries background-check result.
    var osintCheck: OSINTBackgroundCheckResult?

    /// CRM activities timeline.
    var activities: [BooksCRMActivity]

    /// Sales opportunities.
    var opportunities: [BooksCRMOpportunity]

    /// Invoices raised against this contact.
    var invoices: [InvoiceSummary]

    /// DAM assets associated with this contact.
    var assets: [AssetSummary]

    /// Most recent Mail exchange.
    var lastEmail: MailMessageSummary?

    /// Most recent WhatsApp exchange.
    var lastWhatsApp: WhatsAppMessageSummary?

    struct InvoiceSummary: Sendable, Identifiable {
        let id: String
        var number: String
        var status: String
        var total: Double
        var currency: String
        var issueDate: Date?
        var pdfPath: String?
        var dueDate: Date?
        var isOverdue: Bool
    }

    struct AssetSummary: Sendable, Identifiable {
        let id: String
        var filename: String
        var path: String
        var keywords: String?
        var isImage: Bool
    }

    struct MailMessageSummary: Sendable, Identifiable {
        let id: String
        var subject: String
        var sender: String
        var date: Date
        var isRead: Bool
    }

    struct WhatsAppMessageSummary: Sendable, Identifiable {
        let id: String
        var content: String
        var sender: String
        var date: Date
        var isFromMe: Bool
    }
}
