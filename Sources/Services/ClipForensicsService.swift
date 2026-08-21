import Foundation
import Security

// MARK: - Clip Forensics Service
//
// Gathers the forensic metadata for a clip. All fetches are best-effort with
// tight timeouts and NEVER fail the clip — a field that couldn't be captured
// is simply null.

final class ClipForensicsService: Sendable {

    static let shared = ClipForensicsService()

    let session: URLSession
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    // MARK: - Timestamps (offline, always exact)

    func timestamps() -> ClipCaptureMetadata.Timestamps {
        let now = Date()
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        let local = ISO8601DateFormatter()
        local.timeZone = .current
        return ClipCaptureMetadata.Timestamps(
            capturedUTC: utc.string(from: now),
            capturedLocal: local.string(from: now),
            timeZone: TimeZone.current.identifier,
            unixEpoch: Int64(now.timeIntervalSince1970))
    }

    // MARK: - Transport (status, final URL, headers, TLS)

    func transport(for urlString: String) async -> ClipCaptureMetadata.Transport? {
        guard let url = URL(string: urlString) else { return nil }
        let tls = TLSGrabber()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let tlsSession = URLSession(configuration: config, delegate: tls, delegateQueue: nil)

        // Tiny ranged GET — some servers 405 on HEAD; Range keeps the body minimal.
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("SwiftMaestro/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await tlsSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                guard let k = key as? String, let v = value as? String else { continue }
                headers[k.lowercased()] = v
            }
            return ClipCaptureMetadata.Transport(
                requestedURL: urlString,
                finalURL: http.url?.absoluteString,
                httpStatus: http.statusCode,
                serverHeader: headers["server"],
                contentType: headers["content-type"],
                poweredBy: headers["x-powered-by"],
                responseHeaders: headers,
                tlsIssuer: tls.issuer,
                tlsNotAfter: tls.notAfter)
        } catch {
            return ClipCaptureMetadata.Transport(
                requestedURL: urlString, finalURL: nil, httpStatus: nil,
                serverHeader: nil, contentType: nil, poweredBy: nil,
                responseHeaders: [:], tlsIssuer: tls.issuer, tlsNotAfter: tls.notAfter)
        }
    }

    // MARK: - Assemble

    /// Gather everything. Transport + RDAP run concurrently; each may be nil.
    func capture(url: String) async -> ClipCaptureMetadata {
        async let transportTask = transport(for: url)
        async let rdapTask = rdap(for: url)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return ClipCaptureMetadata(
            timestamps: timestamps(),
            transport: await transportTask,
            rdap: await rdapTask,
            appVersion: version,
            captureTool: "SwiftMaestro Web Clipper (Defuddle)")
    }
}

// MARK: - TLS certificate capture

/// URLSession delegate that extracts the leaf TLS certificate's issuer and
/// expiry during the handshake, then defers to default handling.
final class TLSGrabber: NSObject, URLSessionDelegate, @unchecked Sendable {
    private(set) var issuer: String?
    private(set) var notAfter: String?

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return (.performDefaultHandling, nil)
        }
        issuer = Self.issuerSummary(of: leaf)
        notAfter = Self.validityEnd(of: leaf)
        return (.performDefaultHandling, nil)
    }

    private static func issuerSummary(of cert: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDX509V1IssuerName] as CFArray, nil) as? [String: Any],
              let issuerDict = values[kSecOIDX509V1IssuerName as String] as? [String: Any],
              let pairs = issuerDict[kSecPropertyKeyValue as String] as? [[String: Any]] else { return nil }
        let parts = pairs.compactMap { entry -> String? in
            guard let label = entry[kSecPropertyKeyLabel as String] as? String,
                  let value = entry[kSecPropertyKeyValue as String] as? String else { return nil }
            // Shorten the chatty labels
            let short = label
                .replacingOccurrences(of: "Country/Region", with: "C")
                .replacingOccurrences(of: "Organization", with: "O")
                .replacingOccurrences(of: "Common Name", with: "CN")
            return "\(short)=\(value)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func validityEnd(of cert: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(cert, [kSecOIDInvalidityDate] as CFArray, nil) as? [String: Any],
              let dict = values[kSecOIDInvalidityDate as String] as? [String: Any],
              let seconds = dict[kSecPropertyKeyValue as String] as? TimeInterval else { return nil }
        let date = Date(timeIntervalSinceReferenceDate: seconds)
        return ISO8601DateFormatter().string(from: date)
    }
}
