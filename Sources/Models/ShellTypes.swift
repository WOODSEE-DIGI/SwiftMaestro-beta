import Foundation

// MARK: - Shell Policy Types

/// Classification of a shell command by safety policy.
public enum ShellClassification: String, Codable {
    case allowed
    case denied
    case ask
    case unknown
}

/// Alias for ShellClassification - used by ShellApprovalRequest.
typealias ShellPolicyClassification = ShellClassification

/// Rule for shell policy (command pattern to match).
public enum ShellPolicyRule: Codable, Hashable {
    /// A literal string match for a command prefix.
    case literal(String)
    /// A regex pattern to match against the full command string.
    case regex(String)

    /// Check if this rule matches the given command.
    public func matches(_ command: String) -> Bool {
        switch self {
        case .literal(let prefix):
            return command.hasPrefix(prefix)
        case .regex(let pattern):
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                let range = NSRange(command.startIndex..<command.endIndex, in: command)
                return regex.firstMatch(in: command, options: [], range: range) != nil
            } catch {
                return false
            }
        }
    }
}

/// Shell policy configuration.
public struct ShellPolicy: Codable, Hashable {
    public var alwaysAllow: [ShellPolicyRule]
    public var alwaysAsk: [ShellPolicyRule]
    public var neverAllow: [ShellPolicyRule]

    public init(
        alwaysAllow: [ShellPolicyRule] = [],
        alwaysAsk: [ShellPolicyRule] = [],
        neverAllow: [ShellPolicyRule] = []
    ) {
        self.alwaysAllow = alwaysAllow
        self.alwaysAsk = alwaysAsk
        self.neverAllow = neverAllow
    }

    /// Classify a command against the policy lists.
    public func classify(_ command: String) -> ShellClassification {
        if neverAllow.contains(where: { $0.matches(command) }) {
            return .denied
        }
        if alwaysAsk.contains(where: { $0.matches(command) }) {
            return .ask
        }
        if alwaysAllow.contains(where: { $0.matches(command) }) {
            return .allowed
        }
        return .unknown
    }
}

/// Request for shell command approval.
public struct ShellApprovalRequest: Identifiable, Codable {
    public let id: UUID
    let command: String
    let cwd: URL
    let classification: ShellPolicyClassification
    let reason: String?
    let agentName: String

    /// When the approval expires (10 minutes from creation).
    public let createdAt: Date = Date()
    
    /// Compute remaining time until expiration.
    public var timeRemaining: TimeInterval {
        max(0, 600 - createdAt.timeIntervalSinceNow)
    }
    
    /// Check if approval has expired.
    public var isExpired: Bool {
        timeRemaining == 0
    }

    init(
        id: UUID = UUID(),
        command: String,
        cwd: URL,
        classification: ShellPolicyClassification,
        reason: String? = nil,
        agentName: String
    ) {
        self.id = id
        self.command = command
        self.cwd = cwd
        self.classification = classification
        self.reason = reason
        self.agentName = agentName
}

}
