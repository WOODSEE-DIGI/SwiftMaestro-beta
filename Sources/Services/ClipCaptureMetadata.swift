import Foundation

// MARK: - Clip Capture Metadata (forensic model)
//
// Investigative-grade capture metadata for the Web Clipper: exactly when the
// clip was captured (universal + local time), what the server said (status,
// final URL after redirects, response headers, TLS certificate), and who owns
// the domain (RDAP — the HTTPS successor to WHOIS). Written as
// capture-metadata.json in the clip's assets folder.

struct ClipCaptureMetadata: Codable, Sendable {

    struct Timestamps: Codable, Sendable {
        /// ISO8601 UTC, e.g. 2026-08-21T02:10:58Z
        let capturedUTC: String
        /// ISO8601 with the local timezone offset, e.g. 2026-08-21T12:10:58+10:00
        let capturedLocal: String
        /// IANA timezone, e.g. Australia/Sydney
        let timeZone: String
        /// Seconds since 1970 — the tamper-proof numeric form
        let unixEpoch: Int64
    }

    struct Transport: Codable, Sendable {
        let requestedURL: String
        /// Final URL after redirects (differs when the page redirected)
        let finalURL: String?
        let httpStatus: Int?
        let serverHeader: String?
        let contentType: String?
        let poweredBy: String?
        /// All response headers, lowercased keys
        let responseHeaders: [String: String]
        /// Leaf TLS certificate issuer summary
        let tlsIssuer: String?
        /// Leaf TLS certificate expiry, ISO8601
        let tlsNotAfter: String?
    }

    struct RDAPSummary: Codable, Sendable {
        let domain: String
        let registrar: String?
        /// Domain registration date (ISO8601)
        let created: String?
        /// Domain expiry date
        let expires: String?
        /// Last registry update
        let updated: String?
        /// Domain status codes (e.g. "clientTransferProhibited")
        let status: [String]
        let nameservers: [String]
        /// Registrant when not privacy-redacted (usually redacted post-GDPR)
        let registrant: String?
        /// Which RDAP server answered (e.g. rdap.verisign.com)
        let sourceServer: String?
    }

    let timestamps: Timestamps
    let transport: Transport?
    let rdap: RDAPSummary?
    let appVersion: String
    let captureTool: String
}
