import Foundation
import SwiftUI
import AppKit

// MARK: - Runtime permission request store

/// Main-actor observable store that queues runtime permission requests and
/// suspends the calling tool until the user answers. Mirroring OpenCode's
/// permission dock, each request offers Deny / Allow once / Allow always.
@MainActor
public final class PermissionRequestStore: ObservableObject {
    public static let shared = PermissionRequestStore()

    /// The request currently visible in the permission dock.
    @Published public private(set) var currentRequest: PermissionRequest?

    /// Requests waiting behind the currently visible one.
    public private(set) var pendingRequests: [PermissionRequest] = []

    private var results: [UUID: PermissionDecision] = [:]
    private let timeout: TimeInterval = 5 * 60

    private init() {}

    /// Ask the user (via the UI) for permission. Suspends until the user
    /// chooses or the request times out.
    public func request(_ request: PermissionRequest) async -> PermissionDecision {
        pendingRequests.append(request)
        if currentRequest == nil {
            currentRequest = request
            NSLog("[PERMISSION] dock shown for %@ path=%@", request.toolName, request.path ?? "(none)")
        } else {
            NSLog("[PERMISSION] queued for %@ path=%@", request.toolName, request.path ?? "(none)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let decision = results.removeValue(forKey: request.id) {
                advanceQueue(removing: request.id)
                return decision
            }
            if !pendingRequests.contains(where: { $0.id == request.id }) {
                return .deny
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // Timed out — deny and clean up.
        decide(.deny, for: request.id)
        return .deny
    }

    /// Record a user decision. Resumes the waiting request and shows the next
    /// queued request, if any.
    ///
    /// For "Allow always" on a TCC-protected folder (Documents, Desktop,
    /// Downloads, etc.), this presents an `NSOpenPanel` so macOS itself grants
    /// persistent access. If the user cancels the panel, the decision becomes
    /// "deny".
    public func decide(_ decision: PermissionDecision, for requestID: UUID) {
        let effectiveDecision: PermissionDecision
        if decision == .allowAlways,
           currentRequest?.id == requestID,
           let request = pendingRequests.first(where: { $0.id == requestID }),
           let target = request.requestedRoot ?? request.path,
           Self.requiresOpenPanelConfirmation(target) {
            let confirmed = Self.confirmAccessViaOpenPanel(for: target)
            effectiveDecision = confirmed ? .allowAlways : .deny
        } else {
            effectiveDecision = decision
        }

        results[requestID] = effectiveDecision
        NSLog("[PERMISSION] user decided %@ for %@ path=%@", effectiveDecision.rawValue, currentRequest?.toolName ?? "?", currentRequest?.path ?? "(none)")
        if currentRequest?.id == requestID {
            advanceQueue(removing: requestID)
        }
    }

    /// Remove all pending requests and deny any waiting callers. Useful when
    /// an agent run is cancelled.
    public func cancelAll() {
        let ids = pendingRequests.map(\.id)
        for id in ids {
            results[id] = .deny
        }
        pendingRequests.removeAll()
        currentRequest = nil
    }

    private func advanceQueue(removing requestID: UUID) {
        pendingRequests.removeAll { $0.id == requestID }
        currentRequest = pendingRequests.first
    }

    // MARK: - macOS TCC gate for protected folders

    private static let protectedFolderNames = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"]

    private static func requiresOpenPanelConfirmation(_ path: String) -> Bool {
        let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        let home = NSHomeDirectory()
        for name in protectedFolderNames {
            let protected = URL(fileURLWithPath: (home as NSString).appendingPathComponent(name)).standardizedFileURL.path
            if expanded == protected || expanded.hasPrefix(protected + "/") {
                return true
            }
        }
        return false
    }

    private static func confirmAccessViaOpenPanel(for path: String) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Authorize"
        panel.message = "Select the folder SwiftMaestro is allowed to access."
        panel.directoryURL = URL(fileURLWithPath: path)
        return panel.runModal() == .OK
    }
}
