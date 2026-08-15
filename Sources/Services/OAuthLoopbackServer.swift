import Foundation
import Network

// MARK: - Generic loopback OAuth callback server
//
// Generalized from `XeroLoopbackServer` (which stays Xero-specific). Used by
// the plugin bridge's `startOAuth` request: a plugin asks the host to open an
// authorize URL in the default browser, then this one-shot HTTP server on
// 127.0.0.1 captures the provider's redirect, validates `state` (CSRF), and
// hands the authorization code back for the plugin to exchange itself.
//
// Unlike the Xero original, this binds the loopback interface only — the
// callback listener is never reachable from the network.
final class OAuthLoopbackServer: @unchecked Sendable {

    enum ServerError: LocalizedError {
        case portBusy(Int)
        case stateMismatch
        case missingCode
        case timedOut
        case denied(String)

        var errorDescription: String? {
            switch self {
            case .portBusy(let port):
                return "Port \(port) is already in use — the OAuth callback "
                    + "listener can't start. Quit the other app and retry."
            case .stateMismatch:
                return "OAuth callback state mismatch (possible CSRF) — sign-in aborted."
            case .missingCode:
                return "OAuth callback had no authorization code."
            case .timedOut:
                return "OAuth sign-in timed out — no callback received in time."
            case .denied(let description):
                return "OAuth provider denied access: \(description)"
            }
        }
    }

    /// Starts listening on `port` (loopback only) and waits for the single
    /// callback carrying `?code=…&state=…`. Returns the full set of query
    /// items from the callback URL. Cancelling the task shuts the listener.
    static func waitForCallback(
        expectedState: String,
        port: UInt16,
        timeout: Duration = .seconds(120)
    ) async throws -> [String: String] {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw ServerError.portBusy(Int(port))
        }

        return try await withCheckedThrowingContinuation { continuation in
            let box = CompletionBox()
            listener.stateUpdateHandler = { state in
                if case .failed = state, box.tryResume() {
                    continuation.resume(throwing: ServerError.portBusy(Int(port)))
                    listener.cancel()
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
                    data, _, _, _ in
                    let result = parseCallback(data: data, expectedState: expectedState)
                    let page: String
                    switch result {
                    case .success:
                        page = "<h2>Connected.</h2><p>You can close this tab "
                            + "and return to SwiftMaestro.</p>"
                    case .failure(let error):
                        // Escape provider-supplied text (error_description is
                        // attacker-controlled on a crafted redirect) before
                        // reflecting it into the HTML response.
                        page = "<h2>Sign-in failed.</h2>"
                            + "<p>\(Self.htmlEscaped(error.localizedDescription))</p>"
                    }
                    let html = "<!doctype html><html><body style='font-family:sans-serif;"
                        + "margin:3em'>\(page)</body></html>"
                    let httpResponse = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                        + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n"
                        + html
                    connection.send(
                        content: httpResponse.data(using: .utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
                    if box.tryResume() {
                        continuation.resume(with: result)
                        listener.cancel()
                    }
                }
            }
            listener.start(queue: .global())

            // The timeout is the single guaranteed resume path — if the user
            // abandons sign-in, everything tears down afterwards.
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .seconds(Int(timeout.components.seconds))
            ) {
                if box.tryResume() {
                    continuation.resume(throwing: ServerError.timedOut)
                    listener.cancel()
                }
            }
        }
    }

    /// Minimal HTML-escaping for text interpolated into the callback page.
    private static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Holder resuming exactly once.
    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false

        func tryResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }

    /// Extracts query items (or an OAuth error) from the HTTP request bytes.
    /// Validates `state` first — a mismatch is a hard failure, never a code.
    static func parseCallback(
        data: Data?, expectedState: String
    ) -> Result<[String: String], ServerError> {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let line = request.split(separator: "\r\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(target)) else {
            return .failure(.missingCode)
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            let description = items.first(where: { $0.name == "error_description" })?.value
            return .failure(.denied(description ?? error))
        }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            return .failure(.stateMismatch)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(.missingCode)
        }
        var query: [String: String] = [:]
        for item in items { query[item.name] = item.value }
        return .success(query)
    }
}
