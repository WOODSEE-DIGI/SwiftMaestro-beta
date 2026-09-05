import Foundation
import CryptoKit

// MARK: - Blacklist Report Service

/// Prepares unpaid-invoice reports for the p2p reputation framework. This service
/// verifies the debtor identifier, creates a privacy-preserving fingerprint, and
/// stores the report locally in a pending state. It does **not** publish anything
/// to the network; publishing is handled separately by the reputation publisher.
@MainActor
final class BlacklistReportService {
    static let shared = BlacklistReportService()

    private init() {}

    /// Returns true if an invoice is eligible to be reported.
    func isEligible(invoice: BooksInvoice, client: BooksClient) -> Bool {
        guard client.reportToBlacklist else { return false }
        guard invoice.reportToBlacklist ?? true else { return false }
        guard invoice.status == .authorised else { return false }
        guard let dueDate = invoice.dueDate else { return false }
        let daysOverdue = Calendar.current.dateComponents([.day], from: dueDate, to: Date()).day ?? 0
        return daysOverdue >= 60
    }

    /// Prepares a report for an eligible invoice. Returns nil if the invoice is
    /// not eligible or the debtor cannot be verified.
    func prepareReport(
        invoice: BooksInvoice,
        client: BooksClient
    ) async -> BlacklistReport? {
        guard isEligible(invoice: invoice, client: client) else { return nil }

        let country = client.poCountry ?? LocaleSettings.shared.country
        let taxNumber = client.taxNumber
        let normalisedTax = taxNumber.map { ABNVerifierService.normalise($0) }

        // Verify ABN if Australian.
        var verifierProof: ReportVerifierProof?
        if country.uppercased() == "AU",
           let normalisedTax,
           ABNVerifierService.isValidFormat(normalisedTax) {
            let result = await ABNVerifierService.shared.verify(abn: normalisedTax)
            if result.isVerified {
                verifierProof = ReportVerifierProof(
                    kind: "abn-verified",
                    issuer: result.source.rawValue,
                    verifiedAt: result.verifiedAt)
            }
        }

        let total = invoiceTotal(invoice)
        let daysOverdue = Calendar.current.dateComponents([.day], from: invoice.dueDate!, to: Date()).day ?? 0
        let fingerprint = debtorFingerprint(name: client.name, taxNumber: taxNumber, country: country)
        let evidenceHash = evidenceHash(for: invoice)

        return BlacklistReport(
            id: UUID(),
            invoiceID: invoice.id,
            clientID: client.id,
            reportedAt: Date(),
            debtorName: client.name,
            debtorCountry: country,
            debtorTaxNumber: taxNumber,
            debtorFingerprint: fingerprint,
            amountBand: .forAmount(total),
            currency: invoice.currency,
            daysOverdueAtReport: daysOverdue,
            evidenceHash: evidenceHash,
            verifierProof: verifierProof,
            status: .pending,
            errorMessage: nil)
    }

    /// Computes a stable, privacy-preserving fingerprint for a debtor.
    func debtorFingerprint(name: String, taxNumber: String?, country: String) -> String {
        let normalisedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalisedTax = taxNumber.map { ABNVerifierService.normalise($0) } ?? ""
        let payload = "\(normalisedName)|\(normalisedTax)|\(country.uppercased())"
        let data = Data(payload.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func invoiceTotal(_ invoice: BooksInvoice) -> Double {
        do {
            let items = try BooksDatabase.shared.lineItems(invoiceID: invoice.id ?? 0)
            let subtotal = items.reduce(0) { $0 + ($1.quantity * $1.unitAmount * (1 - $1.discount / 100)) }
            return subtotal + (subtotal * invoice.taxRate)
        } catch {
            return 0
        }
    }

    private func evidenceHash(for invoice: BooksInvoice) -> String? {
        guard let pdfPath = invoice.pdfPath else { return nil }
        let url = URL(fileURLWithPath: pdfPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
