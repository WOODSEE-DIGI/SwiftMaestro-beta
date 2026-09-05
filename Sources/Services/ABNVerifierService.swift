import Foundation

// MARK: - ABN Verification Result

struct ABNVerificationResult: Codable, Sendable {
    let abn: String
    let isValid: Bool
    let entityName: String?
    let entityStatus: String?
    let entityType: String?
    let acn: String?
    let gstEffective: String?
    var source: Source
    let verifiedAt: Date
    var errorMessage: String?

    enum Source: String, Codable, Sendable {
        case bulkExtract = "BULK_EXTRACT"
        case liveLookup = "LIVE_LOOKUP"
        case localCache = "LOCAL_CACHE"
        case formatOnly = "FORMAT_ONLY"

        var displayName: String {
            switch self {
            case .bulkExtract: return "ABR/ASIC bulk extract"
            case .liveLookup: return "ABN Lookup"
            case .localCache: return "Local cache"
            case .formatOnly: return "Checksum only"
            }
        }
    }

    var isActive: Bool {
        (entityStatus ?? "").lowercased().contains("active")
    }

    var isVerified: Bool {
        isValid && (entityName != nil || source != .formatOnly)
    }

    enum CodingKeys: String, CodingKey {
        case abn, isValid, entityName, entityStatus, entityType, acn, gstEffective, source, verifiedAt, errorMessage
    }

    init(
        abn: String,
        isValid: Bool,
        entityName: String?,
        entityStatus: String?,
        entityType: String?,
        acn: String?,
        gstEffective: String?,
        source: Source,
        verifiedAt: Date,
        errorMessage: String? = nil
    ) {
        self.abn = abn
        self.isValid = isValid
        self.entityName = entityName
        self.entityStatus = entityStatus
        self.entityType = entityType
        self.acn = acn
        self.gstEffective = gstEffective
        self.source = source
        self.verifiedAt = verifiedAt
        self.errorMessage = errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        abn = try container.decode(String.self, forKey: .abn)
        isValid = try container.decode(Bool.self, forKey: .isValid)
        entityName = try container.decodeIfPresent(String.self, forKey: .entityName)
        entityStatus = try container.decodeIfPresent(String.self, forKey: .entityStatus)
        entityType = try container.decodeIfPresent(String.self, forKey: .entityType)
        acn = try container.decodeIfPresent(String.self, forKey: .acn)
        gstEffective = try container.decodeIfPresent(String.self, forKey: .gstEffective)
        source = try container.decode(Source.self, forKey: .source)
        verifiedAt = try container.decode(Date.self, forKey: .verifiedAt)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

// MARK: - ABN Verifier Service

/// Verifies Australian Business Numbers and Australian Company Numbers using:
///   1. A locally-imported ABR weekly bulk extract (offline, privacy-preserving).
///   2. A locally-imported ASIC company extract.
///   3. Live ABN Lookup search as a fallback.
///
/// The service normalises ABNs/ACNs to digits-only, validates the checksum, and
/// caches verified results on-device. Raw identifiers are never written to chat
/// history or shared memory.
@MainActor
final class ABNVerifierService {
    static let shared = ABNVerifierService()

    private let defaults = UserDefaults.standard
    private let cacheKey = "ABNVerifier.cache"

    /// Parsed ABR bulk-extract records keyed by normalised ABN.
    private var bulkExtract: [String: ABNBulkRecord] = [:]
    /// Parsed ASIC company extract keyed by normalised ACN.
    private var asicExtract: [String: ASICCompanyRecord] = [:]
    /// Parsed ASIC business names extract keyed by normalised ABN.
    private var businessNameExtract: [String: ASICBusinessNameRecord] = [:]

    private init() {
        loadCache()
    }

    // MARK: - Public API

    /// Verifies an ABN. Uses the bulk extract if available, otherwise validates
    /// the checksum and optionally performs a live lookup.
    func verify(
        abn: String,
        allowLiveLookup: Bool = true
    ) async -> ABNVerificationResult {
        let normalised = Self.normalise(abn)
        guard Self.isValidFormat(normalised) else {
            return ABNVerificationResult(
                abn: normalised,
                isValid: false,
                entityName: nil,
                entityStatus: nil,
                entityType: nil,
                acn: nil,
                gstEffective: nil,
                source: .formatOnly,
                verifiedAt: Date(),
                errorMessage: "ABN checksum failed")
        }

        // 1. Cache hit.
        if let cached = cache[normalised], Date().timeIntervalSince(cached.verifiedAt) < 86400 * 7 {
            var copy = cached
            copy.source = .localCache
            return copy
        }

        // 2. Bulk extract hit.
        if let record = bulkExtract[normalised] {
            let result = ABNVerificationResult(
                abn: normalised,
                isValid: true,
                entityName: record.entityName,
                entityStatus: record.entityStatus,
                entityType: record.entityType,
                acn: record.acn,
                gstEffective: record.gstEffective,
                source: .bulkExtract,
                verifiedAt: Date(),
                errorMessage: nil)
            cache[normalised] = result
            saveCache()
            return result
        }

        // 3. Live lookup fallback.
        if allowLiveLookup {
            let result = await liveLookup(abn: normalised)
            cache[normalised] = result
            saveCache()
            return result
        }

        // 4. Format-valid but not in any source.
        return ABNVerificationResult(
            abn: normalised,
            isValid: true,
            entityName: nil,
            entityStatus: nil,
            entityType: nil,
            acn: nil,
            gstEffective: nil,
            source: .formatOnly,
            verifiedAt: Date(),
            errorMessage: "Not found in bulk extract or lookup")
    }

    /// Imports a weekly ABR bulk extract file (CSV or pipe-delimited).
    /// The user downloads the extract from abr.business.gov.au/Tools/BulkExtract
    /// or data.gov.au and points SwiftMaestro at it.
    func importBulkExtract(from url: URL) async throws -> Int {
        let data = try String(contentsOf: url, encoding: .utf8)
        let rows = data.components(separatedBy: .newlines)
        var imported = 0
        var newRecords: [String: ABNBulkRecord] = [:]

        for row in rows {
            let fields = row.components(separatedBy: "|")
            // ABR bulk extract typically has ABN in the first column and
            // entity name in a later column. Header row contains "ABN".
            guard let first = fields.first?.trimmingCharacters(in: .whitespaces),
                  first.allSatisfy({ $0.isNumber }),
                  first.count == 11 else { continue }
            let normalised = Self.normalise(first)
            let record = ABNBulkRecord(
                abn: normalised,
                entityName: fields.count > 2 ? fields[1].trimmingCharacters(in: .whitespaces) : nil,
                entityStatus: fields.count > 3 ? fields[2].trimmingCharacters(in: .whitespaces) : nil,
                entityType: fields.count > 4 ? fields[3].trimmingCharacters(in: .whitespaces) : nil,
                acn: fields.count > 5 ? fields[4].trimmingCharacters(in: .whitespaces) : nil,
                gstEffective: fields.count > 6 ? fields[5].trimmingCharacters(in: .whitespaces) : nil)
            newRecords[normalised] = record
            imported += 1
        }

        bulkExtract = newRecords
        defaults.set(bulkExtract.mapValues { try? JSONEncoder().encode($0) }, forKey: "ABNVerifier.bulkExtract")
        return imported
    }

    /// Verifies an ACN using a locally-imported ASIC company extract.
    func verifyACN(_ acn: String) -> ASICCompanyRecord? {
        let normalised = Self.normalise(acn)
        guard Self.isValidACN(normalised) else { return nil }
        return asicExtract[normalised]
    }

    /// Imports an ASIC company extract (CSV or pipe-delimited). Available from
    /// data.gov.au under Australian Securities and Investments Commission.
    func importASICExtract(from url: URL) async throws -> Int {
        let data = try String(contentsOf: url, encoding: .utf8)
        let rows = data.components(separatedBy: .newlines)
        var imported = 0
        var newRecords: [String: ASICCompanyRecord] = [:]

        for row in rows {
            let fields = row.components(separatedBy: "|")
            guard let first = fields.first?.trimmingCharacters(in: .whitespaces),
                  first.allSatisfy({ $0.isNumber }),
                  first.count == 9 else { continue }
            let normalised = Self.normalise(first)
            let record = ASICCompanyRecord(
                acn: normalised,
                companyName: fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : nil,
                status: fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : nil,
                registrationDate: fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces) : nil,
                reviewDate: fields.count > 4 ? fields[4].trimmingCharacters(in: .whitespaces) : nil)
            newRecords[normalised] = record
            imported += 1
        }

        asicExtract = newRecords
        defaults.set(asicExtract.mapValues { try? JSONEncoder().encode($0) }, forKey: "ABNVerifier.asicExtract")
        return imported
    }

    /// Imports an ASIC Business Names extract (CSV or pipe-delimited). Available
    /// from data.gov.au/data/dataset/asic-business-names.
    func importASICBusinessNames(from url: URL) async throws -> Int {
        let data = try String(contentsOf: url, encoding: .utf8)
        let rows = data.components(separatedBy: .newlines)
        var imported = 0
        var newRecords: [String: ASICBusinessNameRecord] = [:]

        for row in rows {
            let fields = row.components(separatedBy: "|")
            // Business name extract typically has: Business Name | Status |
            // Registration Date | Cancellation Date | Renewal Date | ... | ABN
            guard fields.count >= 8 else { continue }
            let last = fields.last?.trimmingCharacters(in: .whitespaces) ?? ""
            guard last.allSatisfy({ $0.isNumber }), last.count == 11 else { continue }
            let normalisedABN = Self.normalise(last)
            let record = ASICBusinessNameRecord(
                abn: normalisedABN,
                businessName: fields[0].trimmingCharacters(in: .whitespaces),
                status: fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespaces) : nil,
                registrationDate: fields.count > 2 ? fields[2].trimmingCharacters(in: .whitespaces) : nil,
                cancellationDate: fields.count > 3 ? fields[3].trimmingCharacters(in: .whitespaces) : nil)
            newRecords[normalisedABN] = record
            imported += 1
        }

        businessNameExtract = newRecords
        defaults.set(businessNameExtract.mapValues { try? JSONEncoder().encode($0) }, forKey: "ABNVerifier.businessNames")
        return imported
    }

    /// Number of records in each imported extract, exposed for the settings UI.
    var bulkExtractCount: Int { bulkExtract.count }
    var asicExtractCount: Int { asicExtract.count }
    var businessNameExtractCount: Int { businessNameExtract.count }

    /// Clears imported bulk extracts and cached live lookups.
    func reset() {
        bulkExtract = [:]
        asicExtract = [:]
        businessNameExtract = [:]
        cache = [:]
        defaults.removeObject(forKey: "ABNVerifier.bulkExtract")
        defaults.removeObject(forKey: "ABNVerifier.asicExtract")
        defaults.removeObject(forKey: "ABNVerifier.businessNames")
        defaults.removeObject(forKey: cacheKey)
    }

    // MARK: - ABN/ACN format validation

    static func normalise(_ abn: String) -> String {
        abn.filter { $0.isNumber }
    }

    /// ABN checksum validation (Australian Business Register algorithm).
    static func isValidFormat(_ abn: String) -> Bool {
        let digits = normalise(abn)
        guard digits.count == 11, digits.allSatisfy({ $0.isNumber }) else { return false }
        var weights = [10, 1, 3, 5, 7, 9, 11, 13, 15, 17, 19]
        var sum = 0
        for (idx, char) in digits.enumerated() {
            guard let digit = char.wholeNumberValue else { return false }
            if idx == 0 {
                sum += (digit - 1) * weights[idx]
            } else {
                sum += digit * weights[idx]
            }
        }
        return sum % 89 == 0
    }

    /// ACN checksum validation (Australian Securities and Investments Commission).
    static func isValidACN(_ acn: String) -> Bool {
        let digits = normalise(acn)
        guard digits.count == 9, digits.allSatisfy({ $0.isNumber }) else { return false }
        let weights = [8, 7, 6, 5, 4, 3, 2, 1]
        var sum = 0
        for (idx, char) in digits.prefix(8).enumerated() {
            guard let digit = char.wholeNumberValue else { return false }
            sum += digit * weights[idx]
        }
        let complement = (10 - (sum % 10)) % 10
        guard let checkDigit = digits.last?.wholeNumberValue else { return false }
        return complement == checkDigit
    }

    // MARK: - Live lookup

    /// Performs a live lookup against ABN Lookup. In production this should use
    /// the registered web service; this fallback calls the public search page
    /// and parses the response. Returns format-only result if network fails.
    private func liveLookup(abn: String) async -> ABNVerificationResult {
        let url = URL(string: "https://abr.business.gov.au/ABN/View?abn=\(abn)")!
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let html = String(data: data, encoding: .utf8) else {
                return formatOnly(abn: abn)
            }
            let name = Self.scrape(html: html, after: "Entity name:", before: "</")
                ?? Self.scrape(html: html, after: "Trading name:", before: "</")
            let status = Self.scrape(html: html, after: "ABN status:", before: "</")
            let type = Self.scrape(html: html, after: "Entity type:", before: "</")
            let gst = Self.scrape(html: html, after: "GST status:", before: "</")
            return ABNVerificationResult(
                abn: abn,
                isValid: true,
                entityName: name,
                entityStatus: status,
                entityType: type,
                acn: nil,
                gstEffective: gst,
                source: .liveLookup,
                verifiedAt: Date(),
                errorMessage: name == nil ? "Could not parse ABN Lookup response" : nil)
        } catch {
            return formatOnly(abn: abn, error: error.localizedDescription)
        }
    }

    private func formatOnly(abn: String, error: String? = nil) -> ABNVerificationResult {
        ABNVerificationResult(
            abn: abn,
            isValid: true,
            entityName: nil,
            entityStatus: nil,
            entityType: nil,
            acn: nil,
            gstEffective: nil,
            source: .formatOnly,
            verifiedAt: Date(),
            errorMessage: error ?? "Not found in bulk extract or lookup")
    }

    private static func scrape(html: String, after: String, before: String) -> String? {
        guard let afterRange = html.range(of: after) else { return nil }
        let substring = html[afterRange.upperBound...]
        guard let beforeRange = substring.range(of: before) else { return nil }
        let value = String(substring[..<beforeRange.lowerBound])
        // Strip common HTML tags and whitespace.
        return value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    // MARK: - Cache

    private var cache: [String: ABNVerificationResult] = [:]

    private func loadCache() {
        if let data = defaults.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: ABNVerificationResult].self, from: data) {
            cache = decoded
        }
        if let stored = defaults.object(forKey: "ABNVerifier.bulkExtract") as? [String: Data] {
            bulkExtract = stored.compactMapValues { data in
                try? JSONDecoder().decode(ABNBulkRecord.self, from: data)
            }
        }
        if let stored = defaults.object(forKey: "ABNVerifier.asicExtract") as? [String: Data] {
            asicExtract = stored.compactMapValues { data in
                try? JSONDecoder().decode(ASICCompanyRecord.self, from: data)
            }
        }
        if let stored = defaults.object(forKey: "ABNVerifier.businessNames") as? [String: Data] {
            businessNameExtract = stored.compactMapValues { data in
                try? JSONDecoder().decode(ASICBusinessNameRecord.self, from: data)
            }
        }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: cacheKey)
        }
    }
}

// MARK: - Bulk record

private struct ABNBulkRecord: Codable, Sendable {
    let abn: String
    let entityName: String?
    let entityStatus: String?
    let entityType: String?
    let acn: String?
    let gstEffective: String?
}

struct ASICCompanyRecord: Codable, Sendable {
    let acn: String
    let companyName: String?
    let status: String?
    let registrationDate: String?
    let reviewDate: String?

    var isActive: Bool {
        (status ?? "").lowercased().contains("registered")
    }
}

struct ASICBusinessNameRecord: Codable, Sendable {
    let abn: String
    let businessName: String?
    let status: String?
    let registrationDate: String?
    let cancellationDate: String?

    var isActive: Bool {
        let s = (status ?? "").lowercased()
        return s.contains("registered") || s.contains("active")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
