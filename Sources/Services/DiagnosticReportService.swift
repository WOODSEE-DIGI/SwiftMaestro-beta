import AVFoundation
import Foundation

// MARK: - Diagnostic Report Service
//
// Builds and sends an anonymous, user-initiated diagnostic report so problems
// that need a CODE fix (not something self-healing or the Swift Helper can
// patch at runtime) reach the developers with real evidence attached.
//
// PRIVACY CONTRACT (hard requirements, do not weaken):
//   • Every report is a separate, explicit user action — the sheet previews
//     the exact JSON payload and nothing sends until the user clicks Send.
//   • No background/automatic reporting. No standing consent. No telemetry.
//   • Anonymous by construction: no account, no device ID, no name, no file
//     paths (home paths → ~), no machine name, all known Keychain secrets
//     stripped by SecretRedactor. An optional contact email exists ONLY as a
//     deliberately user-filled field for follow-up.
//   • The auth token is a spam hurdle, not a secret — it ships in the binary
//     and only stops drive-by junk POSTs to the endpoint.

/// One section of the report; each maps to a toggle in the sheet.
struct DiagnosticReport: Codable, Sendable {
    var reportVersion: Int = 1
    var createdAt: Date = Date()
    var app: AppMeta
    var userDescription: String
    var contactEmail: String?       // only present when the user typed it
    var crashes: [CrashSection]?
    var selfHealing: String?
    var media: MediaSection?

    struct AppMeta: Codable, Sendable {
        var appVersion: String
        var build: String
        var macOS: String
        var chip: String
    }

    struct CrashSection: Codable, Sendable {
        var name: String            // redacted filename (date+process only)
        var excerpt: String         // redacted, truncated
    }

    struct MediaSection: Codable, Sendable {
        var fileExtension: String   // never the filename
        var probe: String           // ffprobe summary (no paths)
        var avfoundationLoad: String
    }
}

final class DiagnosticReportService: Sendable {
    static let shared = DiagnosticReportService()

    /// Report endpoint (1984 hosting). Spam-hurdle token — not a secret.
    static let endpoint = URL(string: "https://swiftmaestro.com/report.php")!
    static let endpointToken = "sm-report-2026-v1"

    // MARK: - Build

    /// Assemble the report for preview. Everything gathered here is exactly
    /// what the user will read and send.
    func buildReport(
        description: String,
        contactEmail: String?,
        includeCrashes: Bool,
        includeSelfHealing: Bool,
        mediaPath: String?
    ) async -> DiagnosticReport {
        var report = DiagnosticReport(
            app: .init(
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                chip: Self.chipName()
            ),
            userDescription: description,
            contactEmail: contactEmail?.isEmpty == false ? contactEmail : nil
        )

        if includeCrashes {
            report.crashes = recentCrashes()
        }
        if includeSelfHealing {
            report.selfHealing = await selfHealingSummary()
        }
        if let mediaPath, !mediaPath.isEmpty {
            report.media = await mediaSection(path: mediaPath)
        }

        return report
    }

    /// The exact JSON bytes that will be sent — redacted. This is what the
    /// preview shows and what goes on the wire.
    func redactedJSON(for report: DiagnosticReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let raw = try encoder.encode(report)
        return Data(Self.redact(String(decoding: raw, as: UTF8.self)).utf8)
    }

    // MARK: - Redaction

    /// Strip everything that could identify the user or their machine.
    static func redact(_ text: String) -> String {
        var out = text
        let home = NSHomeDirectory()
        out = out.replacingOccurrences(of: home, with: "~")
        if let user = NSUserName() as String? {
            out = out.replacingOccurrences(of: "/Users/\(user)", with: "~")
            out = out.replacingOccurrences(of: user, with: "<user>")
        }
        if let host = Host.current().localizedName, !host.isEmpty {
            out = out.replacingOccurrences(of: host, with: "<host>")
        }
        out = out.replacingOccurrences(of: ProcessInfo.processInfo.hostName, with: "<host>")
        // Known Keychain secrets (tokens, API keys) — the existing safety net.
        out = SecretRedactor.redact(out)
        return out
    }

    // MARK: - Sections

    /// Newest 3 SwiftMaestro crash reports from the last 7 days, excerpts
    /// truncated to 4 KB each after redaction.
    private func recentCrashes() -> [DiagnosticReport.CrashSection] {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return files
            .filter { $0.lastPathComponent.hasPrefix("SwiftMaestro") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      date > cutoff else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .compactMap { url, date in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let excerpt = Self.redact(String(text.prefix(4096)))
                let name = "SwiftMaestro-\(ISO8601DateFormatter().string(from: date)).ips"
                return DiagnosticReport.CrashSection(name: name, excerpt: excerpt)
            }
    }

    /// ToolCallGuardian failure log tail + stats summary.
    private func selfHealingSummary() async -> String {
        var parts: [String] = [await ToolCallGuardian.shared.statsSummary()]
        let logURL = URL(fileURLWithPath: ToolCallGuardian.shared.failureLogPath)
        if let data = try? Data(contentsOf: logURL) {
            let tail = String(decoding: data.suffix(32_768), as: UTF8.self)
            parts.append("Recent tool failures (tail):\n\(Self.redact(tail))")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Media diagnosis for a user-supplied path: codec/container summary and
    /// the AVFoundation load verdict. Filename is reduced to its extension.
    private func mediaSection(path: String) async -> DiagnosticReport.MediaSection? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var probeText = "ffprobe unavailable"
        if let result = try? await FFmpegService().runFFprobe(arguments: [
            "-v", "error", "-hide_banner",
            "-show_entries", "stream=codec_type,codec_name,codec_tag_string:format=format_name,duration",
            "-of", "csv=p=0", url.path,
        ]) {
            probeText = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var avVerdict: String
        do {
            _ = try await AVURLAsset(url: url).load(.duration)
            avVerdict = "loads OK"
        } catch {
            avVerdict = "fails to load: \(error.localizedDescription)"
        }

        return DiagnosticReport.MediaSection(
            fileExtension: url.pathExtension.lowercased(),
            probe: probeText,
            avfoundationLoad: avVerdict
        )
    }

    // MARK: - Send

    enum SendError: LocalizedError {
        case serverRejected(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .serverRejected(let code, let body):
                return "Server rejected the report (HTTP \(code)): \(body.prefix(200))"
            case .badResponse:
                return "The server response could not be read."
            }
        }
    }

    /// POST the redacted payload. Returns the server's reference ID.
    func send(report: DiagnosticReport) async throws -> String {
        let payload = try redactedJSON(for: report)

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.endpointToken, forHTTPHeaderField: "X-SM-Report-Token")
        request.httpBody = payload

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SendError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw SendError.serverRejected(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        struct Reply: Codable { var ok: Bool; var id: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.ok,
              let id = reply.id else {
            throw SendError.badResponse
        }
        return id
    }

    // MARK: - Helpers

    private static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.machine.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.machine.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted to open the diagnostic report sheet. userInfo may carry
    /// "description" (String) and "mediaPath" (String) prefill values.
    static let openDiagnosticReport = Notification.Name("openDiagnosticReport")
}
