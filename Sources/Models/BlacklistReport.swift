import Foundation

// MARK: - Blacklist Report

/// A local, pre-publication record of an unpaid-invoice report. The report is
/// stored in MaestroBooks until the user explicitly chooses to publish it via
/// the p2p reputation framework.
struct BlacklistReport: Identifiable, Codable, Sendable {
    var id: UUID
    var invoiceID: Int64?
    var clientID: Int64?
    var reportedAt: Date
    var debtorName: String
    var debtorCountry: String
    var debtorTaxNumber: String?
    var debtorFingerprint: String
    var amountBand: AmountBand
    var currency: String
    var daysOverdueAtReport: Int
    var evidenceHash: String?
    var verifierProof: ReportVerifierProof?
    var status: Status
    var errorMessage: String?

    enum AmountBand: String, Codable, CaseIterable, Sendable {
        case under1k = "<1k"
        case band1kTo10k = "1k-10k"
        case band10kTo50k = "10k-50k"
        case band50kTo100k = "50k-100k"
        case over100k = ">100k"

        static func forAmount(_ amount: Double) -> AmountBand {
            switch amount {
            case ..<1000: return .under1k
            case 1000..<10000: return .band1kTo10k
            case 10000..<50000: return .band10kTo50k
            case 50000..<100000: return .band50kTo100k
            default: return .over100k
            }
        }
    }

    enum Status: String, Codable, Sendable {
        case pending    // Prepared but not yet published.
        case published  // Published to the p2p network.
        case disputed   // Subject or another party has disputed.
        case withdrawn  // Reporter withdrew the report.
    }
}

struct ReportVerifierProof: Codable, Sendable {
    var kind: String
    var issuer: String
    var verifiedAt: Date
}
