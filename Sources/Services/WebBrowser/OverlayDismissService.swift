import Foundation

// MARK: - Overlay Dismiss Service
//
// Runs the bundled OverlayDismiss.js on a browser tab: clicks close controls
// in visible dialogs (modals, newsletter popups, spin-to-win wheels, cookie
// walls), removes whatever survives, clears backdrops, restores scrolling.
// Used by the SwiftBrowser toolbar button and the browser_dismiss_overlays
// agent tool (research runs hit popup-walled retail sites constantly).

@MainActor
final class OverlayDismissService {
    static let shared = OverlayDismissService()

    struct Result: Sendable {
        let clicked: Int
        let removed: Int
        let scrollRestored: Bool

        var didSomething: Bool { clicked > 0 || removed > 0 || scrollRestored }
        var summary: String {
            var parts: [String] = []
            if clicked > 0 { parts.append("\(clicked) close clicked") }
            if removed > 0 { parts.append("\(removed) removed") }
            if scrollRestored { parts.append("scroll restored") }
            return parts.isEmpty ? "no overlays found" : parts.joined(separator: ", ")
        }
    }

    private let script: String?

    private init() {
        if let url = Bundle.main.url(forResource: "OverlayDismiss", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            script = source
        } else {
            script = nil
            NSLog("[OverlayDismiss] OverlayDismiss.js missing from bundle")
        }
    }

    /// Dismiss overlays on the given tab. Returns nil if the script is missing
    /// or evaluation failed.
    @discardableResult
    func dismiss(on tab: BrowserTab) async -> Result? {
        guard let script else { return nil }
        guard let data = try? await tab.evaluateJavaScript(script),
              let text = String(data: data, encoding: .utf8),
              let decoded = try? JSONDecoder().decode(Payload.self, from: Data(text.replacingOccurrences(of: "'", with: "\"").utf8))
                 ?? Self.decodeLenient(text) else {
            return nil
        }
        return Result(clicked: decoded.clicked, removed: decoded.removed,
                      scrollRestored: decoded.scrollRestored)
    }

    private struct Payload: Decodable {
        let clicked: Int
        let removed: Int
        let scrollRestored: Bool
    }

    /// WKWebView's evaluateJavaScript returns the JSON string itself wrapped in
    /// quotes when the JS returns a string — decode that form directly.
    private static func decodeLenient(_ text: String) -> Payload? {
        // text may be the JSON string, or a quoted JSON string
        if let data = text.data(using: .utf8), let p = try? JSONDecoder().decode(Payload.self, from: data) {
            return p
        }
        guard let unquoted = try? JSONDecoder().decode(String.self, from: Data(text.utf8)),
              let data = unquoted.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}
