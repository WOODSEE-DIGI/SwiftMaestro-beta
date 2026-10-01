import Foundation

/// Shared broker for Finder "Open with SwiftMaestro" requests targeting
/// MaestroDocs. The store holds the URL until the MaestroDocs panel appears
/// (or is already open) and consumes it.
@MainActor
final class MaestroDocsStore {
    @MainActor static let shared = MaestroDocsStore()
    var pendingOpenFileURL: URL?

    private init() {}
}

extension Notification.Name {
    static let maestroDocsOpenFileRequested = Notification.Name("maestroDocs.openFileRequested")
}
