import SwiftUI
import WebKit

/// Hosts one WKWebView-based UI plugin in a workspace panel.
///
/// Security posture: JavaScript runs, but the plugin's ONLY way to reach
/// anything outside its own static content is `window.swiftMaestro.*` (see
/// `PluginBridge`), gated by whatever capabilities its manifest declared.
/// Regular in-page navigation away from the plugin's own bundled content is
/// denied outright (`WKNavigationDelegate`) — a plugin that wants to reach an
/// external API does so through the native `fetch` bridge capability, never
/// by navigating the webview itself there.
struct PluginPanelView: View {
    let manifest: PluginManifest

    @State private var loadError: String?

    var body: some View {
        Group {
            if let entryURL = manifest.entryURL {
                PluginWebView(manifest: manifest, entryURL: entryURL, loadError: $loadError)
            } else {
                ContentUnavailableView(
                    "Plugin Content Missing",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Couldn't resolve \(manifest.entry) for \"\(manifest.name)\".")
                )
            }
        }
        .overlay(alignment: .top) {
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.85), in: Capsule())
                    .padding(.top, 8)
            }
        }
    }
}

private struct PluginWebView: NSViewRepresentable {
    let manifest: PluginManifest
    let entryURL: URL
    @Binding var loadError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(loadError: $loadError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        let bridge = PluginBridge(pluginID: manifest.id, capabilities: manifest.capabilities)
        contentController.add(bridge, name: "swiftMaestroBridge")
        contentController.addUserScript(
            WKUserScript(
                source: PluginBridge.injectedScriptSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        bridge.webView = webView
        context.coordinator.bridge = bridge
        webView.navigationDelegate = context.coordinator

        // allowingReadAccessTo the plugin's own folder (not its parent) so
        // relative asset references (./style.css, ./app.js) resolve, without
        // granting read access any higher up the filesystem than that.
        webView.loadFileURL(entryURL, allowingReadAccessTo: manifest.contentRootURL ?? entryURL)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var bridge: PluginBridge?
        let loadError: Binding<String?>

        init(loadError: Binding<String?>) {
            self.loadError = loadError
        }

        /// Only the plugin's own initial file load may navigate freely;
        /// anything else (a link click, a redirect, window.location change)
        /// is denied. A plugin needing external data uses the `fetch` bridge
        /// capability instead of navigating the webview itself there.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .other, navigationAction.request.url?.isFileURL == true {
                return .allow
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadError.wrappedValue = "Load failed: \(error.localizedDescription)"
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            loadError.wrappedValue = "Load failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    PluginPanelView(manifest: PluginManifest(
        id: "preview", name: "Preview", icon: "puzzlepiece.extension",
        entry: "index.html", version: "1.0.0"))
}
