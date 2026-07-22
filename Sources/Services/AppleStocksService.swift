import Foundation
import AppKit

// MARK: - Apple Stocks service

/// Minimal integration with the Stocks app. Apple does not expose a public
/// API or JXA scripting dictionary for Stocks, so this service only opens the
/// app or a specific symbol when possible.
///
/// The Stocks URL scheme is undocumented. We use `NSWorkspace.open` with a
/// `stocks://` URL as a best-effort, and fall back to launching the app.
@Observable
@MainActor
final class AppleStocksService {

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

    /// Open the Stocks app. If a symbol is provided, we try to open it with a
    /// `stocks://` URL; if that fails, we fall back to just launching the app.
    func openStocks(symbol: String? = nil) -> Bool {
        if let symbol = symbol?.trimmingCharacters(in: .whitespaces), !symbol.isEmpty {
            let clean = symbol.uppercased()
            let urlString = "stocks://symbol=\(clean)"
            if let url = URL(string: urlString), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return AppleMapsService.openApplication(bundleID: "com.apple.stocks")
    }
}
