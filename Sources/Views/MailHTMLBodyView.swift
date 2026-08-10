import SwiftUI
import WebKit
import AppKit

// MARK: - HTML email body view

/// Renders an HTML email body as the sender intended — full styling, colors,
/// and backgrounds — in a WKWebView, like Apple Mail does. Plain-text emails
/// don't come through here (the caller renders those as themed text).
///
/// Privacy: remote resources (images, stylesheets, fonts) are blocked by
/// default via a WKContentRuleList. The caller shows a "Load remote content"
/// affordance; when allowed (per-message or via the persisted default), the
/// rule list is removed and the body reloads.
struct MailHTMLBodyView: NSViewRepresentable {
    let html: String
    let remoteContentAllowed: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        // Transparent so the theme background shows behind unstyled margins;
        // sender-supplied backgrounds still paint over it.
        webView.setValue(false, forKey: "drawsBackground")
        // NOTE: no KVC coordinator-holder here — WKWebView is not KVC-compliant
        // for arbitrary keys (setValue(forKey:) throws NSUnknownKeyException).
        // SwiftUI retains the Coordinator for the representable's lifetime.
        applyRemoteContentRule(block: !remoteContentAllowed, to: webView, coordinator: context.coordinator)
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.remoteAllowed != remoteContentAllowed {
            coordinator.remoteAllowed = remoteContentAllowed
            applyRemoteContentRule(block: !remoteContentAllowed, to: webView, coordinator: coordinator)
            coordinator.loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        } else if coordinator.loadedHTML != html {
            coordinator.loadedHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func applyRemoteContentRule(block: Bool, to webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        guard block else { return }
        // Block remote subresources (images/styles/fonts/media) — tracking
        // pixels included — while keeping the sender's layout and colors.
        let rules = """
        [{
            "trigger": {
                "url-filter": "^https?://",
                "resource-type": ["image", "style-sheet", "script", "font", "media", "svg-document"]
            },
            "action": { "type": "block" }
        }]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "MailRemoteContentBlock", encodedContentRuleList: rules
        ) { list, _ in
            if let list {
                coordinator.currentRuleList = list
                controller.add(list)
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var remoteAllowed = false
        var loadedHTML = ""
        var currentRuleList: WKContentRuleList?

        /// Links open in the user's default browser, never inside the app.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme else {
                return .allow
            }
            if scheme == "http" || scheme == "https",
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
