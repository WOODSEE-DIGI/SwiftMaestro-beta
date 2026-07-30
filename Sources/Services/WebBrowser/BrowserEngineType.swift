import Foundation

/// Which rendering/automation engine backs a browser tab.
/// - `webKit`: Native WKWebView (human browsing, fast, Apple-native).
/// - `chromium`: Local Chromium/Chrome controlled via the Chrome DevTools Protocol
///   (agent automation, full Chrome JavaScript, screenshots, network capture).
enum BrowserEngineType: String, Codable, CaseIterable, Identifiable, Sendable {
    case webKit = "WebKit"
    case chromium = "Chromium"

    var id: String { rawValue }
}
