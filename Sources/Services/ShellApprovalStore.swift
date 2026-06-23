import Foundation

// MARK: - Shell Approval Result

/// Result of an approval action.
public enum ShellApprovalResult: Equatable {
    case approved
    case approvedAndRemember
    case denied
    case expired
}

// MARK: - Shell Approval Store

/// Shared store for tracking pending shell command approvals.
@MainActor
public final class ShellApprovalStore: ObservableObject {

    public static let shared = ShellApprovalStore()

    /// Pending approval requests keyed by UUID.
    @Published public var pendingApprovals: [UUID: ShellApprovalRequest] = [:]

    /// Expiration timeout in seconds (10 minutes).
    public static let expirationTimeout: TimeInterval = 10 * 60

    /// Add a new approval request. Returns the request ID.
    public func addApproval(_ request: ShellApprovalRequest) -> UUID {
        pendingApprovals[request.id] = request
        return request.id
    }

    /// Get an approval request by ID.
    public func getApproval(id: UUID) -> ShellApprovalRequest? {
        pendingApprovals[id]
    }

    /// Approve a pending request. Optionally add to always-allow list.
    public func approve(id: UUID, remember: Bool = false) -> ShellApprovalResult {
        guard let request = pendingApprovals[id] else {
            return .expired
        }

        pendingApprovals.removeValue(forKey: id)

        if remember {
            // Add command prefix to always-allow list
            let prefix = extractCommandPrefix(request.command)
            ShellPolicyStore.shared.addRule(.literal(prefix), to: .alwaysAllow)
        }

        return remember ? .approvedAndRemember : .approved
    }

    /// Deny a pending request.
    public func deny(id: UUID) -> ShellApprovalResult {
        guard pendingApprovals[id] != nil else {
            return .expired
        }

        pendingApprovals.removeValue(forKey: id)
        return .denied
    }

    /// Check if an approval has expired.
    public func isExpired(id: UUID) -> Bool {
        guard let request = pendingApprovals[id] else {
            return true
        }
        return request.isExpired
    }

    /// Clean up expired approvals.
    public func cleanupExpired() {
        let expiredIds = pendingApprovals.filter { $0.value.isExpired }.map { $0.key }
        for id in expiredIds {
            pendingApprovals.removeValue(forKey: id)
        }
    }

    /// Get all pending approvals that haven't expired.
    public var activeApprovals: [ShellApprovalRequest] {
        pendingApprovals.values.filter { !$0.isExpired }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Extract a command prefix for "remember and add to allow list" feature.
    private func extractCommandPrefix(_ command: String) -> String {
        // For commands like "git push origin main", extract "git push"
        let components = command.split(separator: " ")
        if components.count >= 2 {
            return components.prefix(2).joined(separator: " ")
        }
        return command
    }
}
