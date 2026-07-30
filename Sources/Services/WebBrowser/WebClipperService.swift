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

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.navigationDelegate = self
        return view
    }()

    private var hostingWindow: NSWindow?
    private var scriptSource: String?
    private var isLoaded = false
    private var loadTask: Task<Void, Error>?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// Load the bundled clipper JavaScript into the hidden web view.
    func load() async throws {
        guard !isLoaded else { return }
        if let task = loadTask { try await task.value; return }
        loadTask = Task { try await loadOnce() }
        try await loadTask!.value
        loadTask = nil
    }

    private func loadOnce() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
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
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Convert raw HTML into a structured Markdown clip.
    func clip(html: String, url: String) async throws -> WebClipResult {
        try await load()
        let htmlJSON = Self.stringLiteral(html)
        let urlJSON = Self.stringLiteral(url)
        let script = "window.swiftMaestroClip(\(htmlJSON), \(urlJSON))"
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let string = result as? String,
                      let data = string.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(WebClipResult.self, from: data) else {
                    continuation.resume(throwing: WebClipperError.decodingFailed)
                    return
                }
                continuation.resume(returning: decoded)
            }
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

    var errorDescription: String? {
        switch self {
        case .missingScript: return "The bundled Web Clipper script is missing."
        case .decodingFailed: return "Could not decode the clipper result."
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
