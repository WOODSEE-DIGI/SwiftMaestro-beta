import Foundation

/// A single browser tab, backed by either WebKit or a Chromium CDP session.
/// The tab mirrors the active engine's observable properties into its own
/// stored properties so SwiftUI dependency tracking works reliably.
@Observable
@MainActor
final class BrowserTab: Identifiable {
    let id: UUID
    let engineType: BrowserEngineType

    /// Private tabs use a non-persistent data store: cookies, cache, and site
    /// storage vanish when the tab closes. (Chromium tabs are always
    /// session-scoped via a throwaway temp profile.)
    let isPrivate: Bool

    let webKitEngine: WebKitBrowserEngine?
    let chromiumEngine: ChromiumBrowserEngine?

    /// The URL shown in the address bar. Updated from the engine when the user
    /// is not actively editing the field, so the field reflects the loaded page.
    var urlString: String = ""
    var isURLFieldEditing: Bool = false

    var currentURL: URL?

    /// The URL most recently passed to `loadURL`. Set synchronously at request time
    /// (unlike `currentURL`, which only updates once WebKit commits the navigation),
    /// so duplicate-tab detection works even for a tab that is still loading.
    private(set) var requestedURL: URL?

    var title: String = "New Tab"
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var lastHTTPStatus: Int?

    /// Whether the last response was an HTTP error (a dead link), WebKit only.
    var isDeadLink: Bool {
        switch engineType {
        case .webKit: return webKitEngine?.isDeadLink ?? false
        case .chromium: return false
        }
    }

    var error: String? {
        get {
            switch engineType {
            case .webKit: return webKitEngine?.error
            case .chromium: return chromiumEngine?.lastError
            }
        }
        set {
            switch engineType {
            case .webKit: webKitEngine?.error = newValue
            case .chromium: chromiumEngine?.lastError = newValue
            }
        }
    }

    var lastResponse: String? {
        switch engineType {
        case .webKit: return nil
        case .chromium: return chromiumEngine?.lastResponse
        }
    }

    var screenshot: Data? {
        switch engineType {
        case .webKit: return nil
        case .chromium: return chromiumEngine?.screenshot
        }
    }

    init(engineType: BrowserEngineType = .webKit, isPrivate: Bool = false) {
        self.id = UUID()
        self.engineType = engineType
        self.isPrivate = isPrivate
        switch engineType {
        case .webKit:
            let engine = WebKitBrowserEngine(isPrivate: isPrivate)
            self.webKitEngine = engine
            self.chromiumEngine = nil
            engine.onChange = { [weak self] in
                self?.syncWithEngine()
            }
        case .chromium:
            // Chromium tabs are always session-scoped (throwaway temp profile),
            // so isPrivate is informational only there.
            self.webKitEngine = nil
            self.chromiumEngine = ChromiumBrowserEngine()
        }
        syncWithEngine()
    }

    private func syncWithEngine() {
        switch engineType {
        case .webKit:
            currentURL = webKitEngine?.currentURL
            title = webKitEngine?.title ?? "New Tab"
            isLoading = webKitEngine?.isLoading ?? false
            canGoBack = webKitEngine?.canGoBack ?? false
            canGoForward = webKitEngine?.canGoForward ?? false
            lastHTTPStatus = webKitEngine?.lastHTTPStatus
        case .chromium:
            currentURL = chromiumEngine?.currentURL
            title = chromiumEngine?.title ?? "Chromium"
            isLoading = chromiumEngine?.isLoading ?? false
            canGoBack = true
            canGoForward = true
        }
        if !isURLFieldEditing {
            urlString = currentURL?.absoluteString ?? ""
        }
    }

    func loadURL(_ url: URL) async {
        requestedURL = url
        switch engineType {
        case .webKit:
            webKitEngine?.loadURL(url)
        case .chromium:
            await chromiumEngine?.loadURL(url)
        }
    }

    func goBack() async {
        switch engineType {
        case .webKit:
            webKitEngine?.goBack()
        case .chromium:
            _ = try? await chromiumEngine?.evaluateJavaScript("history.back()")
        }
    }

    func goForward() async {
        switch engineType {
        case .webKit:
            webKitEngine?.goForward()
        case .chromium:
            _ = try? await chromiumEngine?.evaluateJavaScript("history.forward()")
        }
    }

    func reload() async {
        switch engineType {
        case .webKit:
            webKitEngine?.reload()
        case .chromium:
            await chromiumEngine?.reload()
        }
    }

    func stopLoading() {
        webKitEngine?.stopLoading()
    }

    /// Wait until the page finishes loading (or the timeout elapses). Used by the
    /// deep-web agent tools so they can read a fully-rendered page in a
    /// background tab before extracting content.
    func waitUntilLoaded(timeout: TimeInterval = 20) async {
        // Give the navigation a brief moment to actually start.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Fail fast on a load error (malformed URL, DNS/unreachable host) so we
            // don't sit out the whole timeout waiting for a page that will never load.
            if error != nil { return }
            if !isLoading && currentURL != nil { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    func evaluateJavaScript(_ script: String) async throws -> Data? {
        switch engineType {
        case .webKit:
            return try await webKitEngine?.evaluateJavaScript(script)
        case .chromium:
            return try await chromiumEngine?.evaluateJavaScript(script)
        }
    }

    func captureScreenshot() async {
        switch engineType {
        case .webKit:
            break
        case .chromium:
            await chromiumEngine?.captureScreenshot()
        }
    }

    func capturePageHTML() async throws -> String {
        let script = "document.documentElement.outerHTML"
        guard let data = try await evaluateJavaScript(script) else {
            throw BrowserTabError.noContent
        }
        switch engineType {
        case .webKit:
            return try JSONDecoder().decode(String.self, from: data)
        case .chromium:
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = top["result"] as? [String: Any],
                  let value = result["value"] as? String else {
                throw BrowserTabError.noContent
            }
            return value
        }
    }
}

enum BrowserTabError: Error, LocalizedError {
    case noContent
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noContent: return "No page content was captured."
        case .timedOut: return "The page's web content process did not respond in time."
        }
    }
}
