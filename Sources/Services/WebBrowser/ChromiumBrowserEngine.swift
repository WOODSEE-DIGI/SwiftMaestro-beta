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

    /// Path to the Chromium/Chrome executable.
    ///
    /// Resolution order (vendored-first — the DMG must be self-contained):
    /// 1. Vendored Playwright "Chrome for Testing" (ships in the app bundle,
    ///    extracted to Application Support with the bundled MCP servers)
    /// 2. Vendored headless shell (same bundle; no visible window, but CDP
    ///    automation — screenshots, JS, network capture — works fully)
    /// 3. User-installed Google Chrome at /Applications
    ///
    /// Assigning a custom path overrides all of the above.
    var executablePath: String = ChromiumBrowserEngine.resolveExecutable()

    /// Cached custom-override flag: once the user (or settings) assigns a path,
    /// stop re-resolving so their choice sticks.
    private var hasCustomPath = false

    static func resolveExecutable() -> String {
        let mcpRoot = "\(NSHomeDirectory())/Library/Application Support/SwiftMaestro/mcp-servers/playwright/.browsers"
        let candidates = [
            // Full "Chrome for Testing" app (headed — visible windows)
            "\(mcpRoot)/chromium-1219/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
            // Headless shell (CDP-only, no window — still automates fully)
            "\(mcpRoot)/chromium_headless_shell-1219/chrome-headless-shell-mac-arm64/chrome-headless-shell",
            // Fallback: user-installed Chrome
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        // Nothing found — return the Chrome default so the error message
        // names a path the user can plausibly install.
        return "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    }

    /// Re-run vendored-first resolution (e.g. after bundled server extraction
    /// completes on first launch). No-op if a custom path was assigned.
    func refreshExecutablePath() {
        guard !hasCustomPath else { return }
        executablePath = Self.resolveExecutable()
    }

    /// Assign a user-chosen executable path (Settings). Locks out auto-resolution.
    func setCustomExecutablePath(_ path: String) {
        executablePath = path
        hasCustomPath = true
    }

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

        // Re-resolve at connect time: on first launch the bundled MCP servers
        // (including the vendored Chromium binaries) may still be extracting
        // when this engine was constructed.
        refreshExecutablePath()

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
