import Foundation
import AppKit

// MARK: - Apple Mail service

/// Integration with Apple Mail, following the same pattern as the other
/// Apple-app bridges (AppleStocksService / AppleNotesService / NumbersService).
///
/// Capabilities:
///   - Launch Mail.app.
///   - Compose via `mailto:` (hands off to the *default* email client — no
///     permission needed, but not guaranteed to be Mail).
///   - Compose a visible draft directly in Mail.app via JXA (forces Mail,
///     requires Automation permission — `com.apple.security.automation.
///     apple-events` entitlement is already present).
///   - Inspect the currently selected message in Mail's front message viewer
///     (subject, sender, Message-ID) via JXA.
///   - Query the local OwnTrack tracking relay (the `TrackingRelayServer`
///     executable from the apple-mail-tracker-private project) for open/click/
///     reply stats on tracked messages.
@Observable
@MainActor
final class AppleMailService {
    static let shared = AppleMailService()

    enum AuthorizationStatus: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var status: AuthorizationStatus = .notDetermined

    /// No permission is required to open Mail or hand it a `mailto:` URL.
    /// The JXA features trigger the standard macOS automation prompt for
    /// Mail.app on first use; there is no up-front API to request it.
    func requestAuthorization() {
        status = .authorized
    }

    // MARK: - Launching Mail

    /// Open Mail.app.
    @discardableResult
    func openMail() -> Bool {
        AppleMapsService.openApplication(bundleID: "com.apple.mail")
    }

    // MARK: - mailto: compose (no automation permission needed)

    /// Compose a message by opening a `mailto:` URL. This goes to the user's
    /// *default* email client, which may not be Mail — use
    /// `composeInMailApp` when the draft must specifically land in Mail.
    @discardableResult
    func compose(to: String = "", cc: String = "", subject: String = "", body: String = "") -> Bool {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.trimmingCharacters(in: .whitespaces)
        var items: [URLQueryItem] = []
        let trimmedCC = cc.trimmingCharacters(in: .whitespaces)
        if !trimmedCC.isEmpty { items.append(URLQueryItem(name: "cc", value: trimmedCC)) }
        if !subject.isEmpty { items.append(URLQueryItem(name: "subject", value: subject)) }
        if !body.isEmpty { items.append(URLQueryItem(name: "body", value: body)) }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - JXA compose (forces Mail, visible draft)

    /// Creates a visible draft in Mail.app itself, regardless of the default
    /// email client. Requires Automation permission for Mail (the user is
    /// prompted by macOS on first use).
    ///
    /// - Returns: Mail's internal id for the new outgoing message.
    @discardableResult
    func composeInMailApp(
        to recipients: [String],
        cc ccRecipients: [String] = [],
        subject: String,
        content: String
    ) async throws -> String {
        let payload: [[String: String]] =
            recipients.map { ["kind": "to", "address": $0] }
            + ccRecipients.map { ["kind": "cc", "address": $0] }
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadJSON = String(decoding: payloadData, as: UTF8.self)

        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            const msg = Mail.OutgoingMessage({ subject: argv[0], content: argv[1], visible: true })
            Mail.outgoingMessages.push(msg)
            const recipients = JSON.parse(argv[2])
            for (const entry of recipients) {
                if (entry.kind === 'cc') {
                    msg.ccRecipients.push(Mail.Recipient({ address: entry.address }))
                } else {
                    msg.toRecipients.push(Mail.Recipient({ address: entry.address }))
                }
            }
            msg.visible = true
            Mail.activate()
            return String(msg.id())
        }
        """
        return try await AppleScriptRunner.run(script, arguments: [subject, content, payloadJSON])
    }

    // MARK: - Selected message inspection

    /// Snapshot of the message currently selected in Mail's front message
    /// viewer. `messageID` is the RFC 822 Message-ID header (angle brackets
    /// included as Mail reports them — normalize before relay lookups).
    struct SelectedMailMessage: Codable, Sendable {
        let messageID: String?
        let subject: String?
        let sender: String?
        let dateSent: String?
        let toRecipients: [String]
    }

    /// Reads the selection of Mail's front message viewer via JXA.
    /// Returns nil when Mail has no viewer open or nothing is selected.
    func selectedMessage() async throws -> SelectedMailMessage? {
        let script = """
        function run(argv) {
            const Mail = Application('Mail')
            const viewers = Mail.messageViewers()
            if (viewers.length === 0) return 'null'
            const selected = viewers[0].selectedMessages()
            if (!selected || selected.length === 0) return 'null'
            const m = selected[0]
            return JSON.stringify({
                messageID: m.messageId(),
                subject: m.subject(),
                sender: m.sender(),
                dateSent: m.dateSent() ? m.dateSent().toISOString() : null,
                toRecipients: m.toRecipients().map(r => r.address())
            })
        }
        """
        let output = try await AppleScriptRunner.run(script)
        guard output != "null", !output.isEmpty, let data = output.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(SelectedMailMessage.self, from: data)
    }

    // MARK: - OwnTrack tracking relay

    /// Base URL of the local OwnTrack relay (`TrackingRelayServer` from the
    /// apple-mail-tracker-private project). Persisted so it survives relaunches
    /// and can follow a non-default relay configuration.
    var relayBaseURLString: String {
        didSet { UserDefaults.standard.set(relayBaseURLString, forKey: Self.relayBaseURLKey) }
    }

    /// Result of the most recent `/health` probe: true = relay reachable,
    /// false = unreachable, nil = not checked yet this session.
    private(set) var relayOnline: Bool?

    private static let relayBaseURLKey = "appleMail.relayBaseURL"
    static let defaultRelayBaseURL = "http://localhost:8087"

    init() {
        relayBaseURLString = UserDefaults.standard.string(forKey: Self.relayBaseURLKey)
            ?? Self.defaultRelayBaseURL
    }

    /// Normalize an RFC 822 Message-ID the same way the relay does
    /// (`normalizeMessageID` in RelayHTTPServer): trim whitespace and angle
    /// brackets. The relay also tries bracket-wrapped candidates server-side,
    /// but sending the normalized form keeps URLs clean.
    /// Pure function — safe to call from any actor.
    nonisolated static func normalizeMessageID(_ messageID: String) -> String {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? trimmed : normalized
    }

    enum RelayError: LocalizedError {
        case invalidBaseURL
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "The OwnTrack relay base URL is not a valid URL."
            case .httpError(let status):
                return "OwnTrack relay returned HTTP \(status)."
            }
        }
    }

    /// Probe the relay's `/health` endpoint and update `relayOnline`.
    @discardableResult
    func checkRelayHealth() async -> Bool {
        guard let url = URL(string: "\(relayBaseURLString)/health") else {
            relayOnline = false
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            relayOnline = ok
            return ok
        } catch {
            relayOnline = false
            return false
        }
    }

    /// Makes sure *some* relay answers at `relayBaseURLString` — starts the
    /// embedded OwnTrack relay (OwnTrackRelayManager) when nothing is
    /// listening. Returns true when a relay is reachable after the call.
    @discardableResult
    func ensureRelayRunning() async -> Bool {
        if await checkRelayHealth() { return true }
        guard relayBaseURLString == Self.defaultRelayBaseURL else {
            return false // custom relay URL: not ours to start
        }
        guard OwnTrackRelayManager.shared.startRelay() else { return false }
        // Give NWListener a beat to bind before re-probing.
        try? await Task.sleep(for: .milliseconds(300))
        return await checkRelayHealth()
    }

    /// Fetch the aggregate open/click/reply summary for a tracked message.
    func trackingSummary(messageID: String) async throws -> MessageTrackingSummary {
        let base = relayBaseURLString
        let normalized = Self.normalizeMessageID(messageID)
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(base)/v1/messages/\(encoded)/summary") else {
            throw RelayError.invalidBaseURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RelayError.invalidBaseURL }
        guard http.statusCode == 200 else { throw RelayError.httpError(http.statusCode) }
        let decoded = try Self.trackingDecoder.decode(MessageSummaryResponse.self, from: data)
        return decoded.summary
    }

    /// Fetch the raw event list for a tracked message (sent/open/click/reply).
    func trackingEvents(messageID: String) async throws -> [TrackingEvent] {
        let base = relayBaseURLString
        let normalized = Self.normalizeMessageID(messageID)
        guard var components = URLComponents(string: "\(base)/v1/events") else {
            throw RelayError.invalidBaseURL
        }
        components.queryItems = [URLQueryItem(name: "messageId", value: normalized)]
        guard let url = components.url else { throw RelayError.invalidBaseURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RelayError.invalidBaseURL }
        guard http.statusCode == 200 else { throw RelayError.httpError(http.statusCode) }
        let decoded = try Self.trackingDecoder.decode(EventListResponse.self, from: data)
        return decoded.events
    }

    /// Matches `JSONDecoder.trackingDecoder` in MailTrackerShared (ISO 8601).
    private static let trackingDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
