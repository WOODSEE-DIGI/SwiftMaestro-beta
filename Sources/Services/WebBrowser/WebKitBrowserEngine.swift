import Foundation
import WebKit
import AppKit

/// WebKit-backed browser engine. Creates and owns a WKWebView so the SwiftUI
/// view can simply present it.
@Observable
@MainActor
final class WebKitBrowserEngine: NSObject {
    let id = UUID()
    let webView: WKWebView

    var currentURL: URL?
    var title: String?
    var isLoading: Bool = false
    var canGoBack: Bool = false
    var canGoForward: Bool = false
    var error: String?

    /// HTTP status of the last main-frame response (e.g. 200, 404). Used to detect
    /// dead links so the agent doesn't mistake a 404 "can't be found" page for a
    /// successfully loaded one.
    var lastHTTPStatus: Int?

    /// Whether the last response was an HTTP error (status >= 400), i.e. a dead link.
    var isDeadLink: Bool { (lastHTTPStatus ?? 200) >= 400 }

    /// Called whenever a KVO-observed engine property changes.
    var onChange: (() -> Void)?

    /// Called when the page requests a new tab: `target=_blank` / `window.open`
    /// (`background == false`, i.e. open and focus), or a Cmd/middle-click on a
    /// link (`background == true`, i.e. open without switching). The store turns
    /// this into a real app tab.
    var onRequestNewTab: ((URL, Bool) -> Void)?

    private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        setupObservations()
    }

    func loadURL(_ url: URL) {
        error = nil
        lastHTTPStatus = nil
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    /// Evaluate JS with a hard timeout. The naive `withCheckedThrowingContinuation`
    /// only resumes when WebKit's completion handler fires — so if the tab's
    /// WebContent process is hung or dead (which happens with background/offscreen
    /// tabs), the completion never fires and the caller hangs FOREVER (the 6-hour
    /// deep_fetch stall). The timeout guarantees a resume; a resume-once guard
    /// prevents a double-resume if the completion fires late.
    func evaluateJavaScript(_ script: String, timeout: TimeInterval = 15) async throws -> Data? {
        let once = ResumeOnceGuard<Data?>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.resume(continuation, with: .failure(BrowserTabError.timedOut))
            }
            self.webView.evaluateJavaScript(script) { result, error in
                timeoutTask.cancel()
                if let error {
                    once.resume(continuation, with: .failure(error))
                } else if let result {
                    once.resume(continuation, with: .success(Self.jsonData(from: result)))
                } else {
                    once.resume(continuation, with: .success(nil))
                }
            }
        }
    }

    /// Serialize any JS result to JSON data without risking an
    /// `NSInvalidArgumentException`. WKWebView results are always property-list
    /// types, but scalars (String/Number/Bool) are not valid *top-level* JSON
    /// objects, so a plain `data(withJSONObject:)` raises an uncatchable ObjC
    /// exception on them (the `browser_read`/`browser_eval` crash).
    /// `.fragmentsAllowed` permits scalar top-level values.
    private static func jsonData(from result: Any) -> Data {
        if JSONSerialization.isValidJSONObject(result),
           let data = try? JSONSerialization.data(withJSONObject: result) {
            return data
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
            return data
        }
        // Defensive fallback (shouldn't happen for WKWebView results, which are
        // always property-list types): encode a description as a JSON string.
        let fallback = String(describing: result)
        return (try? JSONEncoder().encode(fallback)) ?? Data()
    }

    func takeSnapshot(timeout: TimeInterval = 15) async throws -> Data? {
        let once = ResumeOnceGuard<Data?>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.resume(continuation, with: .failure(BrowserTabError.timedOut))
            }
            let configuration = WKSnapshotConfiguration()
            self.webView.takeSnapshot(with: configuration) { image, error in
                timeoutTask.cancel()
                if let error {
                    once.resume(continuation, with: .failure(error))
                } else if let image = image,
                          let tiff = image.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let png = bitmap.representation(using: .png, properties: [:]) {
                    once.resume(continuation, with: .success(png))
                } else {
                    once.resume(continuation, with: .success(nil))
                }
            }
        }
    }

    private func setupObservations() {
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.currentURL = self.webView.url
                self.onChange?()
            }
        })
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.title = self.webView.title
                self.onChange?()
            }
        })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.isLoading = self.webView.isLoading
                self.onChange?()
            }
        })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.canGoBack = self.webView.canGoBack
                self.onChange?()
            }
        })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            Task { @MainActor in
                self.canGoForward = self.webView.canGoForward
                self.onChange?()
            }
        })
    }
}

extension WebKitBrowserEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Capture the main-frame HTTP status so dead links (404 etc.) are detectable.
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            lastHTTPStatus = http.statusCode
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Cmd+click or middle-click on a link opens it in a background tab instead
        // of navigating the current one. Everything else is left alone.
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            let openInBackground = navigationAction.modifierFlags.contains(.command)
                || navigationAction.buttonNumber == 2
            if openInBackground {
                onRequestNewTab?(url, true)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}

extension WebKitBrowserEngine: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A link with target=_blank (or window.open) would normally spawn a popup
        // web view. Instead, route it into a new app tab and suppress the popup.
        if let url = navigationAction.request.url {
            onRequestNewTab?(url, false)
        }
        return nil
    }
}

/// Guards a `CheckedContinuation` so it is resumed exactly once. Used when racing a
/// WebKit callback against a timeout — whichever fires first wins; the loser is
/// dropped, avoiding both a double-resume crash and a never-resumed leak.
/// Shared with WebClipperService, whose clip/load evaluations get the same
/// hard-timeout treatment (the 14-minute browser_read stall).
final class ResumeOnceGuard<T: Sendable>: @unchecked Sendable {
    private var resumed = false
    private let lock = NSLock()

    func resume(_ continuation: CheckedContinuation<T, Error>, with result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(with: result)
    }
}
