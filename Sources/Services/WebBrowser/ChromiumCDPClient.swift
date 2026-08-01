import Foundation
import Darwin

/// Errors thrown by the Chromium CDP client.
enum ChromiumCDPError: Error, CustomStringConvertible {
    case notConnected
    case encodingFailed
    case noWebSocketURL
    case executableNotFound(String)
    case launchFailed(String)
    case timeout
    case cdpError(String)
    case unexpectedResponse

    var description: String {
        switch self {
        case .notConnected: return "CDP client is not connected"
        case .encodingFailed: return "Failed to encode CDP message"
        case .noWebSocketURL: return "Could not obtain a Chromium debugger WebSocket URL"
        case .executableNotFound(let path): return "Chromium executable not found at \(path)"
        case .launchFailed(let msg): return "Failed to launch Chromium: \(msg)"
        case .timeout: return "Timed out waiting for Chromium to start"
        case .cdpError(let msg): return "CDP error: \(msg)"
        case .unexpectedResponse: return "Unexpected response from Chromium"
        }
    }
}

/// Minimal asynchronous client for Chrome DevTools Protocol over a WebSocket.
/// Launches a local Chromium/Chrome process, creates a debug page, and exposes
/// `send(method:params:)` for CDP commands.
actor ChromiumCDPClient {
    private var process: Process?
    private var webSocketTask: URLSessionWebSocketTask?
    private var messageID: Int = 0
    private var pending: [Int: PendingRequest] = [:]
    private var eventHandler: (@Sendable (String, Data) -> Void)?

    var isConnected: Bool { webSocketTask != nil }

    func setEventHandler(_ handler: @escaping @Sendable (String, Data) -> Void) {
        eventHandler = handler
    }


    /// Launch a local Chromium process if necessary, create a debug page, and
    /// connect to it via WebSocket.
    func connect(executablePath: String, port: Int = 9222) async throws {
        guard webSocketTask == nil else { return }

        let baseURL = URL(string: "http://localhost:\(port)")!
        let isRunning = await portIsReachable(port: port)

        if !isRunning {
            try launchProcess(executablePath: executablePath, port: port)
            try await waitForPort(port: port, timeout: 15)
        }

        let listURL = baseURL.appendingPathComponent("json/list")
        let (listData, _) = try await URLSession.shared.data(from: listURL)
        let pages = (try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]]) ?? []

        let pageURL: URL
        if let first = pages.first,
           let wsURLString = first["webSocketDebuggerUrl"] as? String,
           let url = URL(string: wsURLString) {
            pageURL = url
        } else {
            let newURL = baseURL.appendingPathComponent("json/new")
            var components = URLComponents(url: newURL, resolvingAgainstBaseURL: true)!
            components.queryItems = [URLQueryItem(name: "url", value: "about:blank")]
            let (newData, _) = try await URLSession.shared.data(from: components.url!)
            guard let page = try JSONSerialization.jsonObject(with: newData) as? [String: Any],
                  let wsURLString = page["webSocketDebuggerUrl"] as? String,
                  let url = URL(string: wsURLString) else {
                throw ChromiumCDPError.noWebSocketURL
            }
            pageURL = url
        }

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: pageURL)
        webSocketTask?.resume()
        receiveLoop()

        // Enable the domains we need for browsing and automation.
        _ = try? await send(method: "Page.enable", params: [:])
        _ = try? await send(method: "Runtime.enable", params: [:])
    }

    /// Send a CDP command and wait for its response.
    func send(method: String, params: [String: Any]) async throws -> Data {
        guard let task = webSocketTask else {
            throw ChromiumCDPError.notConnected
        }

        let id = nextMessageID
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChromiumCDPError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(id: id, continuation: continuation)
            self.pending[id] = request
            task.send(.string(text)) { [weak self] error in
                if let error {
                    Task { [weak self] in
                        await self?.complete(id: id, result: .failure(error))
                    }
                }
            }
        }
    }

    /// Close the WebSocket and terminate the Chromium process if we started it.
    func close() async {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        if let process {
            process.terminate()
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            self.process = nil
        }

        for request in pending.values {
            request.complete(.failure(ChromiumCDPError.notConnected))
        }
        pending.removeAll()
    }

    // MARK: - Private

    private func portIsReachable(port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)/json/version") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func launchProcess(executablePath: String, port: Int) throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw ChromiumCDPError.executableNotFound(executablePath)
        }

        let profileDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftmaestro-chromium-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--remote-debugging-port=\(port)",
            "--headless=new",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-default-apps",
            "--disable-background-timer-throttling",
            "--disable-renderer-backgrounding",
            "--user-data-dir=\(profileDir.path)",
            "about:blank"
        ]
        process.terminationHandler = { [weak self] process in
            Task { [weak self] in
                await self?.processTerminated()
            }
        }
        try process.run()
        self.process = process
    }

    private func waitForPort(port: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        guard let url = URL(string: "http://localhost:\(port)/json/version") else {
            throw ChromiumCDPError.timeout
        }
        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return }
            } catch {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw ChromiumCDPError.timeout
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    Task { [weak self] in
                        await self?.handleMessage(text)
                    }
                }
                Task { [weak self] in
                    await self?.receiveLoop()
                }
            case .failure(let error):
                Task { [weak self] in
                    await self?.failAll(error)
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let id = json["id"] as? Int {
            if let errorInfo = json["error"] as? [String: Any],
               let message = errorInfo["message"] as? String {
                complete(id: id, result: .failure(ChromiumCDPError.cdpError(message)))
            } else if let result = json["result"] {
                // The CDP `result` object always has at least a `type` key (it's a
                // valid top-level JSON object), so this is safe — but guard anyway
                // so a scalar can never raise an uncatchable NSInvalidArgumentException.
                let resultData = (try? JSONSerialization.data(withJSONObject: result))
                    ?? (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]))
                    ?? Data()
                complete(id: id, result: .success(resultData))
            } else {
                complete(id: id, result: .success(Data()))
            }
        } else if let method = json["method"] as? String {
            let params = json["params"] as? [String: Any] ?? [:]
            let paramsData = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
            eventHandler?(method, paramsData)
        }
    }

    private func complete(id: Int, result: Result<Data, Error>) {
        guard let request = pending[id] else { return }
        pending[id] = nil
        request.complete(result)
    }

    private func failAll(_ error: Error) {
        for request in pending.values {
            request.complete(.failure(error))
        }
        pending.removeAll()
    }

    private func processTerminated() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private var nextMessageID: Int {
        messageID += 1
        return messageID
    }
}

// MARK: - Pending Request

private final class PendingRequest {
    let id: Int
    private let continuation: CheckedContinuation<Data, Error>
    private var completed = false

    init(id: Int, continuation: CheckedContinuation<Data, Error>) {
        self.id = id
        self.continuation = continuation
    }

    func complete(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
