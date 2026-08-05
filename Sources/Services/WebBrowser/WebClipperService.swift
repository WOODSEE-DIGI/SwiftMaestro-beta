import Foundation
import WebKit
import AppKit

/// Clips the current web page into a Markdown note in the SwiftMaestro Notes
/// vault. The actual extraction logic is a bundled JavaScript port of the
/// Obsidian Web Clipper extraction engine (Defuddle + Turndown) that runs in
/// a hidden WKWebView.
@MainActor
final class WebClipperService: NSObject {
    static let shared = WebClipperService()

    private var _webView: WKWebView?
    /// Factory-backed webview: resetWebView() nils the storage so the next
    /// access builds a genuinely fresh WebContent process with the delegate
    /// attached — the wedge-recovery path after a hard timeout.
    private var webView: WKWebView {
        if let existing = _webView { return existing }
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.navigationDelegate = self
        _webView = view
        return view
    }

    private var hostingWindow: NSWindow?
    private var scriptSource: String?
    private var isLoaded = false
    private var loadTask: Task<Void, Error>?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?
    private var loadOnceGuard: ResumeOnceGuard<Void>?

    /// Load the bundled clipper JavaScript into the hidden web view.
    func load() async throws {
        guard !isLoaded else { return }
        if let task = loadTask { try await task.value; return }
        loadTask = Task { try await loadOnce() }
        try await loadTask!.value
        loadTask = nil
    }

    private func loadOnce() async throws {
        // Hard timeout: if the hidden webview's WebContent process wedges during
        // about:blank load or script injection, the navigation delegate /
        // evaluateJavaScript completion never fires and the caller hangs FOREVER.
        // The timeout routes through finishLoad like any other failure, and the
        // ResumeOnceGuard drops whichever resume loses the race.
        let once = ResumeOnceGuard<Void>()
        self.loadOnceGuard = once
        defer { self.loadOnceGuard = nil }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.loadContinuation = continuation
                self.loadTimeoutTask = Task {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    self.finishLoad(error: WebClipperError.timedOut)
                }
                ensureHostWindow()
                guard let scriptURL = Bundle.main.url(forResource: "swiftmaestro-clipper", withExtension: "js") else {
                    finishLoad(error: WebClipperError.missingScript)
                    return
                }
                do {
                    self.scriptSource = try String(contentsOf: scriptURL, encoding: .utf8)
                } catch {
                    finishLoad(error: error)
                    return
                }
                // Load a blank page first so the JS engine has a proper DOM context
                // before we evaluate the large bundled clipper script.
                webView.load(URLRequest(url: URL(string: "about:blank")!))
            }
        } catch {
            // A timed-out/wedged webview will never become usable — tear it down
            // so the next load() gets a fresh process instead of hanging again.
            if case WebClipperError.timedOut = error { resetWebView() }
            throw error
        }
    }

    private func ensureHostWindow() {
        guard hostingWindow == nil else { return }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.orderBack(nil)
        hostingWindow = window
    }

    private func injectScript() {
        guard let script = scriptSource else {
            finishLoad(error: WebClipperError.missingScript)
            return
        }
        let wrapped = "(function(){\n" + script + "\n})();"
        webView.evaluateJavaScript(wrapped) { _, error in
            if let error {
                self.finishLoad(error: error)
            } else {
                self.isLoaded = true
                self.finishLoad(error: nil)
            }
        }
    }

    private func finishLoad(error: Error?) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        loadOnceGuard?.resume(continuation, with: result)
    }

    /// Tear down a wedged hidden webview so the next load() gets a fresh
    /// WebContent process. Called after a hard timeout — a wedged process does
    /// not recover, and keeping it would hang every subsequent clip.
    private func resetWebView() {
        isLoaded = false
        scriptSource = nil
        loadTask = nil
        _webView?.navigationDelegate = nil
        _webView?.removeFromSuperview()
        _webView = nil
        hostingWindow?.contentView = nil
        hostingWindow = nil
    }

    /// Convert raw HTML into a structured Markdown clip.
    /// Hard timeout: Defuddle+Turndown on a huge SPA DOM (or a wedged hidden
    /// WebContent process) can stall the evaluateJavaScript callback forever —
    /// the 14-minute browser_read stall on a Shopify storefront. Whichever of
    /// the completion / timeout fires first wins; on timeout the webview is
    /// treated as wedged and torn down for the next caller.
    func clip(html: String, url: String, timeout: TimeInterval = 45) async throws -> WebClipResult {
        try await load()
        let htmlJSON = Self.stringLiteral(html)
        let urlJSON = Self.stringLiteral(url)
        let script = "window.swiftMaestroClip(\(htmlJSON), \(urlJSON))"
        let once = ResumeOnceGuard<WebClipResult>()
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebClipResult, Error>) in
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    once.resume(continuation, with: .failure(WebClipperError.timedOut))
                }
                webView.evaluateJavaScript(script) { result, error in
                    timeoutTask.cancel()
                    if let error {
                        once.resume(continuation, with: .failure(error))
                        return
                    }
                    guard let string = result as? String,
                          let data = string.data(using: .utf8),
                          let decoded = try? JSONDecoder().decode(WebClipResult.self, from: data) else {
                        once.resume(continuation, with: .failure(WebClipperError.decodingFailed))
                        return
                    }
                    once.resume(continuation, with: .success(decoded))
                }
            }
        } catch {
            if case WebClipperError.timedOut = error { resetWebView() }
            throw error
        }
    }

    private static func stringLiteral(_ string: String) -> String {
        // Produce a valid JS/JSON string literal (quoted + escaped). Use JSONEncoder
        // rather than JSONSerialization: a bare String is not a valid *top-level*
        // JSONSerialization object and raises an uncatchable NSInvalidArgumentException.
        if let data = try? JSONEncoder().encode(string),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\"\""
    }
}

extension WebClipperService: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        injectScript()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoad(error: error)
    }
}

enum WebClipperError: Error, LocalizedError {
    case missingScript
    case decodingFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingScript: return "The bundled Web Clipper script is missing."
        case .decodingFailed: return "Could not decode the clipper result."
        case .timedOut: return "The clipper extraction timed out."
        }
    }
}

struct WebClipResult: Codable {
    let title: String
    let url: String
    let excerpt: String
    let author: String
    let published: String
    let site: String
    let markdown: String
    let html: String
}
