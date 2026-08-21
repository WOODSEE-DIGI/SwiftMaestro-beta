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
                          var decoded = try? JSONDecoder().decode(WebClipResult.self, from: data) else {
                        once.resume(continuation, with: .failure(WebClipperError.decodingFailed))
                        return
                    }
                    decoded.fullHtml = html
                    once.resume(continuation, with: .success(decoded))
                }
            }
        } catch {
            if case WebClipperError.timedOut = error { resetWebView() }
            throw error
        }
    }

    /// Enrich a clip with metadata — no-op shim kept for API compatibility:
    /// the rebuilt clipper bundle (Defuddle 0.16 full-metadata entry) returns
    /// all metadata fields from clip() in a single pass.
    func enrichWithMetadata(_ result: WebClipResult, html: String, markdown: String, timeout: TimeInterval = 20) async -> WebClipResult {
        result
    }

    /// Full clip: content extraction + metadata. The bundle returns all
    /// fields from one evaluation — clipFull is the canonical entry point.
    func clipFull(html: String, url: String, timeout: TimeInterval = 45) async throws -> WebClipResult {
        try await clip(html: html, url: url, timeout: timeout)
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
    // var: asset capture rewrites image links to local paths
    var markdown: String
    var html: String

    // Full metadata (returned by the rebuilt clipper bundle in one pass)
    var description: String = ""
    var domain: String = ""
    var favicon: String = ""
    var image: String = ""
    var language: String = ""
    var wordCount: Int = 0
    var metaTags: [ClipMetaTag] = []
    var schemaOrg: [ClipSchemaOrg] = []
    var extractorType: String = ""
    var extractorVariables: [String: String] = [:]
    var fullHtml: String = ""

    enum CodingKeys: String, CodingKey {
        case title, url, excerpt, author, published, site, markdown, html
        case description, domain, favicon, image, language, wordCount
        case metaTags, schemaOrg, fullHtml
        case extractorType
        case extractorVariables = "variables"
    }

    /// Memberwise init (plain-text fallbacks, tests).
    init(title: String, url: String, excerpt: String, author: String,
         published: String, site: String, markdown: String, html: String) {
        self.title = title
        self.url = url
        self.excerpt = excerpt
        self.author = author
        self.published = published
        self.site = site
        self.markdown = markdown
        self.html = html
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        excerpt = (try? c.decode(String.self, forKey: .excerpt)) ?? ""
        author = (try? c.decode(String.self, forKey: .author)) ?? ""
        published = (try? c.decode(String.self, forKey: .published)) ?? ""
        site = (try? c.decode(String.self, forKey: .site)) ?? ""
        markdown = (try? c.decode(String.self, forKey: .markdown)) ?? ""
        html = (try? c.decode(String.self, forKey: .html)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        domain = (try? c.decode(String.self, forKey: .domain)) ?? ""
        favicon = (try? c.decode(String.self, forKey: .favicon)) ?? ""
        image = (try? c.decode(String.self, forKey: .image)) ?? ""
        language = (try? c.decode(String.self, forKey: .language)) ?? ""
        wordCount = (try? c.decode(Int.self, forKey: .wordCount)) ?? 0
        metaTags = (try? c.decode([ClipMetaTag].self, forKey: .metaTags)) ?? []
        extractorType = (try? c.decode(String.self, forKey: .extractorType)) ?? ""
        extractorVariables = (try? c.decode([String: String].self, forKey: .extractorVariables)) ?? [:]
        fullHtml = (try? c.decode(String.self, forKey: .fullHtml)) ?? ""
        // schemaOrg may be a single object, an array of objects, or null
        if let array = try? c.decode([ClipSchemaOrg].self, forKey: .schemaOrg) {
            schemaOrg = array
        } else if let single = try? c.decode(ClipSchemaOrg.self, forKey: .schemaOrg) {
            schemaOrg = [single]
        } else {
            schemaOrg = []
        }
    }
}

struct ClipMetaTag: Codable {
    let name: String?
    let property: String?
    let content: String
}

/// A parsed JSON-LD block. Kept as raw JSON string so any schema.org shape
/// round-trips without a rigid Codable model.
struct ClipSchemaOrg: Codable {
    let raw: String

    init(raw: String) { self.raw = raw }

    init(from decoder: Decoder) throws {
        // JSON-LD blocks are arbitrary objects — capture the raw value.
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodableValue].self) {
            let data = try JSONEncoder().encode(dict)
            raw = String(data: data, encoding: .utf8) ?? "{}"
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            let data = try JSONEncoder().encode(arr)
            raw = String(data: data, encoding: .utf8) ?? "[]"
        } else {
            raw = "{}"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let data = raw.data(using: .utf8),
           let obj = try? JSONDecoder().decode(AnyCodableValue.self, from: data) {
            try container.encode(obj)
        } else {
            try container.encode(raw)
        }
    }
}

/// Minimal any-JSON Codable box for schema.org pass-through.
enum AnyCodableValue: Codable {
    case string(String), number(Double), bool(Bool), array([AnyCodableValue]), object([String: AnyCodableValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([AnyCodableValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: AnyCodableValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
}
