import Foundation

/// Chromium-backed browser engine. Controls a local Chrome/Chromium via CDP.
@Observable
@MainActor
final class ChromiumBrowserEngine {
    let id = UUID()

    var currentURL: URL?
    var title: String?
    var isLoading: Bool = false
    var lastError: String?
    var lastResponse: String?
    var screenshot: Data?

    /// Path to the Chromium/Chrome executable. Defaults to Google Chrome.
    var executablePath: String = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private var client: ChromiumCDPClient?

    func loadURL(_ url: URL) async {
        await run {
            let result = try await self.client!.send(method: "Page.navigate", params: ["url": url.absoluteString])
            self.lastResponse = String(data: result, encoding: .utf8)
            if let error = Self.errorText(from: result) {
                self.lastError = error
            } else {
                self.currentURL = url
                self.isLoading = true
            }
        }
    }

    func goBack() async {
        _ = try? await evaluateJavaScript("history.back()")
    }

    func goForward() async {
        _ = try? await evaluateJavaScript("history.forward()")
    }

    func reload() async {
        await run {
            let result = try await self.client!.send(method: "Page.reload", params: ["ignoreCache": true])
            self.lastResponse = String(data: result, encoding: .utf8)
            self.isLoading = true
        }
    }

    func evaluateJavaScript(_ script: String) async throws -> Data? {
        try await runWithResult {
            let result = try await self.client!.send(
                method: "Runtime.evaluate",
                params: [
                    "expression": script,
                    "returnByValue": true,
                    "awaitPromise": true
                ]
            )
            self.lastResponse = String(data: result, encoding: .utf8)
            return result
        }
    }

    func captureScreenshot() async {
        await run {
            let result = try await self.client!.send(
                method: "Page.captureScreenshot",
                params: ["format": "png", "fromSurface": true]
            )
            let json = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any]
            if let base64 = json?["data"] as? String,
               let data = Data(base64Encoded: base64) {
                self.screenshot = data
            } else {
                self.lastError = "Screenshot did not return image data"
            }
            self.lastResponse = String(data: result, encoding: .utf8)
        }
    }

    // MARK: - Private

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await ensureClient()
            try await operation()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func runWithResult<T>(_ operation: () async throws -> T) async throws -> T {
        try await ensureClient()
        return try await operation()
    }

    private func ensureClient() async throws {
        if let client = client, await client.isConnected { return }

        let client = ChromiumCDPClient()
        await client.setEventHandler { [weak self] method, data in
            Task { @MainActor [weak self] in
                self?.handleEvent(method: method, data: data)
            }
        }
        try await client.connect(executablePath: executablePath)
        self.client = client
    }

    private func handleEvent(method: String, data: Data) {
        switch method {
        case "Page.loadEventFired":
            isLoading = false
            Task { await updateTitle() }
        case "Page.domContentEventFired":
            break
        default:
            break
        }
    }

    private func updateTitle() async {
        guard let data = try? await evaluateJavaScript("document.title"),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = top["result"] as? [String: Any],
              let value = result["value"] as? String else {
            return
        }
        title = value
    }

    private static func errorText(from data: Data) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = json["errorText"] as? String else {
            return nil
        }
        return error
    }
}
