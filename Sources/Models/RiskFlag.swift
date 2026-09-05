import Foundation
import CommonCrypto

// MARK: - Risk Flag

/// A local cache entry representing a reported debtor on the p2p blacklist.
/// Sensitive details are never stored here — only a fingerprint, severity
/// metadata, and provenance.
struct RiskFlag: Identifiable, Codable, Sendable {
    var id: String { fingerprint }

    /// Stable fingerprint of the reported entity: hash of normalised
    /// business name + tax identifier + country.
    let fingerprint: String

    /// Highest severity among aggregated reports for this fingerprint.
    var severity: Severity

    /// Number of distinct reports contributing to this flag.
    var reportCount: Int

    /// Date of the most recent report.
    var lastReported: Date

    /// Source of the flag: local reports, p2p gossip, or a verifier oracle.
    var source: Source

    /// Human-readable reason summary (no PII).
    var reason: String

    enum Severity: String, Codable, CaseIterable, Sendable {
        case info, low, medium, high, critical

        var displayName: String {
            switch self {
            case .info:    return "Info"
            case .low:     return "Low Risk"
            case .medium:  return "Medium Risk"
            case .high:    return "High Risk"
            case .critical:return "Critical Risk"
            }
        }

        var color: String {
            switch self {
            case .info:    return "blue"
            case .low:     return "yellow"
            case .medium:  return "orange"
            case .high:    return "red"
            case .critical:return "purple"
            }
        }
    }

    enum Source: String, Codable, Sendable {
        case local, p2p, verifier
    }
}

// MARK: - Fingerprinting

enum ContactFingerprint {
    /// Normalises a business name for hashing: lowercased, stripped of
    /// punctuation/whitespace, common suffixes removed.
    static func normaliseName(_ name: String) -> String {
        let suffixes = [
            "pty ltd", "pty limited", "ltd", "limited", "inc", "incorporated",
            "llc", "corp", "corporation", "plc", "gmbh", "sa", "nv", "bv"
        ]
        var cleaned = name.lowercased()
        cleaned = cleaned.components(separatedBy: CharacterSet.letters.inverted)
            .joined()
        for suffix in suffixes {
            if cleaned.hasSuffix(suffix) {
                cleaned.removeLast(suffix.count)
                break
            }
        }
        return cleaned
    }

    /// Normalises a tax identifier: digits only.
    static func normaliseTaxID(_ taxID: String) -> String {
        taxID.filter { $0.isNumber }
    }

    /// Computes a stable fingerprint from the most reliable identifiers.
    /// Falls back to name-only if no tax ID is provided, which is weaker but
    /// still useful for fuzzy matching.
    static func make(name: String, taxID: String?, country: String = "AU") -> String {
        let n = normaliseName(name)
        let t = taxID.map(normaliseTaxID) ?? ""
        let payload = t.isEmpty ? "\(n)|\(country)" : "\(n)|\(t)|\(country)"
        let data = Data(payload.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// Minimal SHA-256 helper to avoid importing CryptoKit everywhere.
private enum SHA256 {
    static func hash(data: Data) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest
    }
}
