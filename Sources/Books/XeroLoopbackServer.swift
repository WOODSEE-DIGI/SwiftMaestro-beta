import Foundation
import Network

// MARK: - Loopback OAuth callback server
//
// Xero PKCE desktop flow: the browser redirects to
// http://localhost:53682/callback?code=…&state=… after consent. This tiny
// one-shot HTTP server on 127.0.0.1 captures that redirect, returns a
// "you can close this tab" page, and hands the code back.
final class XeroLoopbackServer: @unchecked Sendable {

    enum ServerError: LocalizedError {
        case portBusy(Int)
        case stateMismatch
        case missingCode
        case timedOut
        case xeroDenied(String)

        var errorDescription: String? {
            switch self {
            case .portBusy(let port):
                return "Port \(port) is already in use — the Xero callback "
                    + "listener can't start. Quit the other app and retry."
            case .stateMismatch:
                return "Xero callback state mismatch (possible CSRF) — sign-in aborted."
            case .missingCode:
                return "Xero callback had no authorization code."
            case .timedOut:
                return "Xero sign-in timed out (2 minutes) — no callback received."
            case .xeroDenied(let description):
                return "Xero denied access: \(description)"
            }
        }
    }

    /// Starts listening on XeroAPIClient.redirectURI's port and waits for the
    /// one callback. Cancelling the task shuts the listener down.
    static func waitForCallback(
        expectedState: String, port: UInt16 = 53682, timeout: Duration = .seconds(120)
    ) async throws -> String {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
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
                        page = "<h2>Connected to Xero.</h2><p>You can close this tab "
                            + "and return to SwiftMaestro.</p>"
                    case .failure(let error):
                        page = "<h2>Xero sign-in failed.</h2>"
                            + "<p>\(error.localizedDescription)</p>"
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

    /// Holder resuming exactly once; also carries listener teardown on cancel.
    private final class CompletionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        var onCancel: (() -> Void)?

        func tryResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }

    /// Extracts code/state (or a Xero error) from the HTTP request bytes.
    static func parseCallback(data: Data?, expectedState: String) -> Result<String, ServerError> {
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
            return .failure(.xeroDenied(description ?? error))
        }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            return .failure(.stateMismatch)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(.missingCode)
        }
        return .success(code)
    }
}
