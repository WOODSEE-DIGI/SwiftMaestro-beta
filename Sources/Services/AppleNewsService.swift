import Foundation
import AppKit

// MARK: - Apple News service

/// Minimal integration with the Apple News app. Apple does not expose a public
/// API or JXA scripting dictionary for News, so this service only opens the app
/// or a specific article/topic URL.
///
/// Supported URLs:
///   - `https://apple.news/...` links (handed off to the default browser / News)
///   - `applenews://` to open the News app directly
///   - `applenews://search?search_term=...` (undocumented, best-effort)
@Observable
@MainActor
final class AppleNewsService {

    enum AuthorizationStatus: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var status: AuthorizationStatus = .notDetermined

    // No permission is required to open the app.
    func requestAuthorization() {
        status = .authorized
    }

    /// Open Apple News. If a URL or search term is provided, try to route to it.
    func openNews(url: String? = nil, search: String? = nil) -> Bool {
        if let urlString = url?.trimmingCharacters(in: .whitespaces), !urlString.isEmpty {
            guard let parsed = URL(string: urlString) else { return false }
            return NSWorkspace.shared.open(parsed)
        }

        if let search = search?.trimmingCharacters(in: .whitespaces), !search.isEmpty {
            let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
            let urlString = "applenews://search?search_term=\(encoded)"
            if let parsed = URL(string: urlString), NSWorkspace.shared.open(parsed) {
                return true
            }
        }

        return AppleMapsService.openApplication(bundleID: "com.apple.news")
    }
}
