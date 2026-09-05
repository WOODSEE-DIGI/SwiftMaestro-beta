import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - CRM Contact Card tools

/// Agent-facing tools for the CRM Contact Card. Agents can query the same
/// aggregated client/lead profile that the CRM contact card displays.
extension MaestroTools {

    static func registerContactCardTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "contact_card_find",
                spec: contactCardToolSpecs[0],
                category: ToolCategory.system.rawValue,
                handler: { call in await contactCardFind(call) }),
        ])
    }

    static var contactCardToolSpecs: [ToolSpec] {
        [
            rawSpec(
                "contact_card_find",
                "Build a unified CRM contact-card profile for a person or business by "
                    + "searching MaestroBooks clients and CRM leads. "
                    + "Returns contact details, risk flag, opportunities, activities, invoices and DAM assets.",
                properties: [
                    "name": ["type": "string", "description": "Person or company name to look up."],
                    "email": ["type": "string", "description": "Optional email address to narrow the match."],
                ],
                required: ["name"]),
        ]
    }

    private struct FindArgs: Decodable {
        let name: String
        let email: String?
    }

    // MARK: - Handler

    @MainActor
    private static func contactCardFind(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: FindArgs.self) else {
            return errorJSON("contact_card_find could not decode arguments.")
        }
        let queryName = args.name
        let queryEmail = args.email

        guard !queryName.isEmpty else {
            return errorJSON("contact_card_find requires a 'name' value.")
        }

        // 1. Try MaestroBooks clients by exact name.
        do {
            if let client = try BooksDatabase.shared.client(named: queryName) {
                let profile = await Task { @MainActor in
                    await CRMContactCardService.shared.profile(for: client)
                }.value
                return encodeProfile(profile)
            }
        } catch {
            // Fall through.
        }

        // 2. Try CRM leads by exact name.
        do {
            let leads = try BooksDatabase.shared.crmLeads()
            if let lead = leads.first(where: { $0.name.caseInsensitiveCompare(queryName) == .orderedSame }) {
                let profile = await Task { @MainActor in
                    await CRMContactCardService.shared.profile(for: lead)
                }.value
                return encodeProfile(profile)
            }
        } catch {
            // Fall through.
        }

        // 3. Try macOS Contacts (requires prior authorization).
        do {
            let contacts = try await Task { @MainActor in
                let contactsService = ContactsService()
                return try await contactsService.searchContacts(query: queryName)
            }.value
            if let match = contacts.first(where: { contact in
                if let email = queryEmail,
                   contact.emailAddresses.contains(where: { $0.value.caseInsensitiveCompare(email) == .orderedSame }) {
                    return true
                }
                return contact.displayName.caseInsensitiveCompare(queryName) == .orderedSame
            }) ?? contacts.first {
                let profile = CRMContactCardProfile(
                    id: match.emailAddresses.first?.value ?? match.phoneNumbers.first?.value ?? UUID().uuidString,
                    name: match.displayName,
                    company: match.organizationName,
                    email: match.emailAddresses.first?.value,
                    phone: match.phoneNumbers.first?.value,
                    taxNumber: nil,
                    country: nil,
                    sourceLabel: "\(match.displayName) — Contacts",
                    client: nil,
                    lead: nil,
                    riskFlag: RiskFlagService.shared.flag(for: match.displayName, taxID: nil),
                    activities: [],
                    opportunities: [],
                    invoices: [],
                    assets: [],
                    lastEmail: nil,
                    lastWhatsApp: nil)
                return encodeProfile(profile)
            }
        } catch {
            // Fall through.
        }

        return errorJSON("No CRM contact card found for '\(queryName)'.")
    }

    // MARK: - Encoding

    private static func encodeProfile(_ profile: CRMContactCardProfile) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(ProfileSnapshot(profile: profile)),
              let json = String(data: data, encoding: .utf8) else {
            return errorJSON("Failed to encode contact card profile.")
        }
        return json
    }

    /// A flatter, tool-friendly snapshot of the profile.
    private struct ProfileSnapshot: Encodable {
        let name: String
        let company: String?
        let source: String
        let email: String?
        let phone: String?
        let taxNumber: String?
        let riskFlagSeverity: String?
        let opportunities: [OpportunitySnapshot]
        let activities: [ActivitySnapshot]
        let invoices: [InvoiceSnapshot]
        let assets: [AssetSnapshot]
        let lastEmail: EmailSnapshot?

        init(profile: CRMContactCardProfile) {
            self.name = profile.name
            self.company = profile.company
            self.source = profile.sourceLabel
            self.email = profile.email
            self.phone = profile.phone
            self.taxNumber = profile.taxNumber
            self.riskFlagSeverity = profile.riskFlag?.severity.displayName
            self.opportunities = profile.opportunities.map { OpportunitySnapshot($0) }
            self.activities = profile.activities.map { ActivitySnapshot($0) }
            self.invoices = profile.invoices.map { InvoiceSnapshot($0) }
            self.assets = profile.assets.map { AssetSnapshot($0) }
            self.lastEmail = profile.lastEmail.map { EmailSnapshot($0) }
        }
    }

    private struct OpportunitySnapshot: Encodable {
        let title: String
        let stage: String
        let value: Double?
        let probability: Int
        init(_ o: BooksCRMOpportunity) {
            self.title = o.title
            self.stage = o.stage.displayName
            self.value = o.value
            self.probability = o.probability
        }
    }

    private struct ActivitySnapshot: Encodable {
        let kind: String
        let subject: String
        let dueDate: Date?
        let completed: Bool
        init(_ a: BooksCRMActivity) {
            self.kind = a.kind.rawValue
            self.subject = a.subject
            self.dueDate = a.dueDate
            self.completed = a.completedDate != nil
        }
    }

    private struct InvoiceSnapshot: Encodable {
        let number: String
        let status: String
        let total: Double
        let currency: String
        init(_ i: CRMContactCardProfile.InvoiceSummary) {
            self.number = i.number
            self.status = i.status
            self.total = i.total
            self.currency = i.currency
        }
    }

    private struct AssetSnapshot: Encodable {
        let filename: String
        let path: String
        init(_ a: CRMContactCardProfile.AssetSummary) {
            self.filename = a.filename
            self.path = a.path
        }
    }

    private struct EmailSnapshot: Encodable {
        let subject: String
        let sender: String
        let date: Date
        init(_ e: CRMContactCardProfile.MailMessageSummary) {
            self.subject = e.subject
            self.sender = e.sender
            self.date = e.date
        }
    }
}
