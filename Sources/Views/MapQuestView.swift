import SwiftUI
import WebKit

// MARK: - MapQuest panel

/// A first-class SwiftMaestro panel that loads the free MapQuest website
/// (https://www.mapquest.com). Advertising containers and empty ad placeholders
/// are hidden via content-blocking rules and injected CSS, while MapQuest
/// branding, login/sign-up, upsells, and all functional map controls remain
/// visible. No paid MapQuest API is used during beta.
struct MapQuestView: View {
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        MapQuestWebView()
            .background(theme.background)
    }
}

// MARK: - WebView

private struct MapQuestWebView: NSViewRepresentable {

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()

        // Inject CSS to collapse ad-related containers while keeping MapQuest
        // branding and functional UI intact.
        contentController.addUserScript(
            WKUserScript(
                source: MapQuestWebView.adHidingCSS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        // Inject a post-load cleanup pass that removes any remaining
        // advertisement containers or empty placeholder boxes.
        contentController.addUserScript(
            WKUserScript(
                source: MapQuestWebView.adCleanupScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Compile and install content-blocking rules that target common ad
        // networks and trackers. This reduces data use and hides ad frames.
        let ruleList = MapQuestWebView.blockingRuleList
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "MapQuestAdBlocking",
            encodedContentRuleList: ruleList
        ) { list, error in
            if let list {
                webView.configuration.userContentController.add(list)
            } else if let error {
                print("[MapQuest] Failed to compile content rules: \(error.localizedDescription)")
            }
        }

        if let url = URL(string: "https://www.mapquest.com") {
            let request = URLRequest(url: url)
            webView.load(request)
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: - Content blocking

    /// JSON content-rule list targeting advertisement/tracker domains and
    /// MapQuest ad-specific URL patterns. Action is "block" so the resources
    /// are not loaded at all.
    private static let blockingRuleList = """
    [
        {
            "trigger": {
                "url-filter": ".*",
                "if-domain": [
                    "doubleclick.net",
                    "googleadservices.com",
                    "googlesyndication.com",
                    "google-analytics.com",
                    "googletagmanager.com",
                    "googletagservices.com",
                    "facebook.com",
                    "fbcdn.net",
                    "amazon-adsystem.com",
                    "adsystem.amazon.com",
                    "adnxs.com",
                    "adsrvr.org",
                    "advertising.com",
                    "adsafeprotected.com",
                    "moatads.com",
                    "outbrain.com",
                    "taboola.com",
                    "criteo.com",
                    "scorecardresearch.com",
                    "quantserve.com"
                ]
            },
            "action": { "type": "block" }
        },
        {
            "trigger": {
                "url-filter": "cdn\\.ad\\.",
                "resource-type": ["script", "image", "stylesheet"]
            },
            "action": { "type": "block" }
        }
    ]
    """

    /// CSS injected at document start to hide ad containers and empty
    /// placeholders. Selectors are conservative: they target common ad-related
    /// markup patterns rather than MapQuest's functional UI.
    private static let adHidingCSS: String = {
        let css = """
        /* Collapse common ad-related containers and empty placeholder boxes */
        [class*="ad-"],
        [class*="ads-"],
        [class*="advertisement"],
        [class*="sponsored"],
        [id*="ad-"],
        [id*="ads-"],
        [id*="advertisement"],
        iframe[src*="ads"],
        iframe[src*="doubleclick"],
        iframe[src*="googleads"],
        div:empty {
            display: none !important;
            visibility: hidden !important;
            height: 0 !important;
            min-height: 0 !important;
            overflow: hidden !important;
        }
        """
        return wrapCSS(css)
    }()

    /// JavaScript injected at document end to walk the DOM and remove any
    /// elements that are explicitly labeled as advertisements or that appear
    /// to be empty placeholder boxes left behind by ad blocking.
    private static let adCleanupScript: String = {
        let script = """
        (function() {
            function cleanup() {
                const selectors = [
                    '[class*="ad-"]', '[class*="ads-"]', '[class*="advertisement"]',
                    '[class*="sponsored"]', '[id*="ad-"]', '[id*="ads-"]', '[id*="advertisement"]'
                ];
                document.querySelectorAll(selectors.join(', ')).forEach(el => el.remove());

                // Remove empty placeholder boxes that are tall enough to have been ads.
                document.querySelectorAll('div').forEach(el => {
                    if (!el.textContent.trim().length && el.children.length === 0) {
                        const rect = el.getBoundingClientRect();
                        if (rect.height > 80 && rect.width > 80) {
                            el.remove();
                        }
                    }
                });
            }
            cleanup();
            // Re-run after any lazy-loaded ad containers appear.
            setInterval(cleanup, 2000);
        })();
        """
        return script
    }()

    private static func wrapCSS(_ css: String) -> String {
        let escaped = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
            const style = document.createElement('style');
            style.textContent = "\(escaped)";
            document.head.appendChild(style);
        })();
        """
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            print("[MapQuest] Navigation failed: \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            print("[MapQuest] Provisional navigation failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Preview

#Preview {
    MapQuestView()
        .frame(width: 800, height: 600)
}
