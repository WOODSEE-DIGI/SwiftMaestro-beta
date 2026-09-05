import Foundation
import GRDB

// MARK: - CRM Contact Card Service

/// Builds a unified CRM contact card from a MaestroBooks client or CRM lead.
/// The card surfaces the sales pipeline, activity timeline, invoices, and
/// related DAM assets.
@MainActor
final class CRMContactCardService {
    static let shared = CRMContactCardService()

    weak var whatsAppService: WhatsAppService?

    private init() {}

    func profile(for client: BooksClient) async -> CRMContactCardProfile {
        var profile = CRMContactCardProfile(
            id: "client-\(client.id ?? 0)",
            name: client.name,
            company: nil,
            email: client.email,
            phone: client.phone,
            taxNumber: client.taxNumber,
            country: client.poCountry,
            sourceLabel: "\(client.name) — MaestroBooks",
            client: client,
            lead: nil,
            riskFlag: RiskFlagService.shared.flag(for: client.name, taxID: client.taxNumber, country: client.poCountry),
            abnVerification: nil,
            osintCheck: nil,
            activities: [],
            opportunities: [],
            invoices: [],
            assets: [],
            lastEmail: nil,
            lastWhatsApp: nil)

        await populateABNVerification(for: &profile)
        await populateOSINTCheck(for: &profile)
        await populateActivities(for: &profile)
        await populateOpportunities(for: &profile)
        await populateInvoices(for: &profile)
        await populateAssets(for: &profile)
        await populateCommunications(for: &profile, email: client.email, phone: client.phone)
        return profile
    }

    func profile(for lead: BooksCRMLead) async -> CRMContactCardProfile {
        var profile = CRMContactCardProfile(
            id: "lead-\(lead.id ?? 0)",
            name: lead.name,
            company: lead.company,
            email: lead.email,
            phone: lead.phone,
            taxNumber: lead.taxNumber,
            country: lead.country,
            sourceLabel: "\(lead.name) — Lead",
            client: nil,
            lead: lead,
            riskFlag: RiskFlagService.shared.flag(for: lead.name, taxID: lead.taxNumber, country: lead.country),
            abnVerification: nil,
            osintCheck: nil,
            activities: [],
            opportunities: [],
            invoices: [],
            assets: [],
            lastEmail: nil,
            lastWhatsApp: nil)

        await populateABNVerification(for: &profile)
        await populateOSINTCheck(for: &profile)
        await populateActivities(for: &profile)
        await populateOpportunities(for: &profile)
        await populateAssets(for: &profile)
        await populateCommunications(for: &profile, email: lead.email, phone: lead.phone)
        return profile
    }

    // MARK: - Populators

    private func populateABNVerification(for profile: inout CRMContactCardProfile) async {
        guard let taxNumber = profile.taxNumber, !taxNumber.isEmpty,
              (profile.country ?? LocaleSettings.shared.country).uppercased() == "AU" else { return }
        let normalised = ABNVerifierService.normalise(taxNumber)
        guard ABNVerifierService.isValidFormat(normalised) else { return }
        profile.abnVerification = await ABNVerifierService.shared.verify(abn: normalised)
    }

    private func populateOSINTCheck(for profile: inout CRMContactCardProfile) async {
        guard LocaleSettings.shared.p2pBlacklistEnabled || OSINTIndustriesService.shared.isConfigured else { return }
        profile.osintCheck = await OSINTIndustriesService.shared.backgroundCheck(
            email: profile.email,
            phone: profile.phone,
            username: nil,
            name: profile.company ?? profile.name)
    }

    private func populateActivities(for profile: inout CRMContactCardProfile) async {
        do {
            if let clientID = profile.client?.id {
                profile.activities = try BooksDatabase.shared.crmActivities(contactKind: "client", contactID: clientID)
            } else if let leadID = profile.lead?.id {
                profile.activities = try BooksDatabase.shared.crmActivities(contactKind: "lead", contactID: leadID)
            }
        } catch {
            profile.activities = []
        }
    }

    private func populateOpportunities(for profile: inout CRMContactCardProfile) async {
        do {
            let all = try BooksDatabase.shared.crmOpportunities()
            if let clientID = profile.client?.id {
                profile.opportunities = all.filter { $0.clientID == clientID }
            } else if let leadID = profile.lead?.id {
                profile.opportunities = all.filter { $0.leadID == leadID }
            }
        } catch {
            profile.opportunities = []
        }
    }

    private func populateInvoices(for profile: inout CRMContactCardProfile) async {
        guard let clientID = profile.client?.id else { return }
        do {
            let all = try BooksDatabase.shared.invoices()
            let items = try BooksDatabase.shared.lineItems(invoiceID: 0) // placeholder
            profile.invoices = try all.filter { $0.clientID == clientID }.map { invoice in
                let lineItems = try BooksDatabase.shared.lineItems(invoiceID: invoice.id ?? 0)
                let subtotal = lineItems.reduce(0) { $0 + ($1.quantity * $1.unitAmount * (1 - $1.discount / 100)) }
                let total = subtotal + (subtotal * invoice.taxRate)
                let isOverdue = invoice.status == .authorised
                    && (invoice.dueDate ?? .distantFuture) < Date()
                return CRMContactCardProfile.InvoiceSummary(
                    id: invoice.number,
                    number: invoice.number,
                    status: invoice.status.displayName,
                    total: total,
                    currency: invoice.currency,
                    issueDate: invoice.issueDate,
                    pdfPath: invoice.pdfPath,
                    dueDate: invoice.dueDate,
                    isOverdue: isOverdue)
            }
        } catch {
            profile.invoices = []
        }
    }

    private func populateAssets(for profile: inout CRMContactCardProfile) async {
        let query = profile.name
        guard !query.isEmpty else { return }
        do {
            let assets = try DAMDatabase.shared.searchAssets(
                matching: query,
                folder: nil,
                minRating: 0,
                limit: 20,
                offset: 0)
            profile.assets = assets.map { asset in
                let path = asset.path
                let isImage = ["jpg", "jpeg", "png", "heic", "tiff", "webp", "gif"]
                    .contains((path as NSString).pathExtension.lowercased())
                return CRMContactCardProfile.AssetSummary(
                    id: String(asset.id ?? 0),
                    filename: asset.filename,
                    path: path,
                    keywords: asset.userKeywords ?? asset.xattrKeywords,
                    isImage: isImage)
            }
        } catch {
            profile.assets = []
        }
    }

    private func populateCommunications(for profile: inout CRMContactCardProfile, email: String?, phone: String?) async {
        if let email, !email.isEmpty {
            profile.lastEmail = await lastEmail(from: email)
        }
        if let phone, !phone.isEmpty {
            profile.lastWhatsApp = await lastWhatsApp(from: phone)
        }
    }

    private func lastEmail(from email: String) async -> CRMContactCardProfile.MailMessageSummary? {
        guard MailEnvelopeIndex.shared.isAvailable else { return nil }
        do {
            let rows = try MailEnvelopeIndex.shared.messages(
                mailboxIDs: nil,
                search: email,
                limit: 1)
            guard let row = rows.first else { return nil }
            return CRMContactCardProfile.MailMessageSummary(
                id: String(row.id),
                subject: row.subject,
                sender: row.senderDisplay,
                date: row.date,
                isRead: row.isRead)
        } catch {
            return nil
        }
    }

    private func lastWhatsApp(from phone: String) async -> CRMContactCardProfile.WhatsAppMessageSummary? {
        guard let service = whatsAppService, service.status == .connected else { return nil }
        await service.loadChats()
        let normalized = phone.filter { $0.isNumber }
        guard let chat = service.chats.first(where: {
            let chatDigits = $0.jid.filter { $0.isNumber }
            return chatDigits.contains(normalized) || normalized.contains(chatDigits)
        }) else { return nil }
        await service.loadMessages(chatJID: chat.jid, limit: 1)
        guard let message = service.messages.last,
              let content = message.content else { return nil }
        return CRMContactCardProfile.WhatsAppMessageSummary(
            id: message.id,
            content: content,
            sender: message.isFromMe ? "Me" : chat.displayName,
            date: message.timestamp ?? Date(),
            isFromMe: message.isFromMe)
    }
}
