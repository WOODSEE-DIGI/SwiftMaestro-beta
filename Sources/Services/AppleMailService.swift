import Foundation
import AppKit
import ApplicationServices

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

    // MARK: - Automation permission preflight

    enum AutomationPermission: Equatable {
        case authorized
        case denied
        case notDetermined
    }

    /// Checks Apple Events permission for Mail.app WITHOUT triggering the
    /// prompt (askUserIfNeeded=false). Lets the UI fail fast with a useful
    /// message instead of waiting out a JXA timeout when the user denied
    /// (or hasn't yet answered) the automation prompt.
    nonisolated static func mailAutomationPermission() -> AutomationPermission {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: "com.apple.mail")
        guard let aeDesc = descriptor.aeDesc else { return .notDetermined }
        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc, typeWildCard, typeWildCard, false
        )
        switch Int(status) {
        case 0: return .authorized
        case -1743: return .denied // errAEEventNotPermitted
        default: return .notDetermined
        }
    }

    /// Deep link to System Settings → Privacy & Security → Automation.
    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
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

    // MARK: - Message-ID normalization

    /// Normalize an RFC 822 Message-ID: trim whitespace and angle brackets.
    /// Pure function — safe to call from any actor.
    nonisolated static func normalizeMessageID(_ messageID: String) -> String {
        let trimmed = messageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? trimmed : normalized
    }

    // MARK: - Selected message inspection

    /// Snapshot of the message currently selected in Mail's front message
    /// viewer. `messageID` is the RFC 822 Message-ID header (angle brackets
    /// included as Mail reports them).
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
}
