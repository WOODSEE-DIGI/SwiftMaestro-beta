import Foundation

// MARK: - Runtime permission request model

/// The kind of filesystem access being requested. Used by the UI to choose
/// wording and icons.
public enum PermissionKind: String, Sendable {
    case fileRead
    case fileWrite
    case directoryList
    case directoryCreate
    case fileDelete
    case fileCopy
    case fileMove
    case externalDirectory
    case tool
}

/// User decision for a single permission request.
public enum PermissionDecision: String, Sendable {
    case allowOnce
    case allowAlways
    case deny
}

/// A single runtime permission prompt shown to the user when a tool wants to
/// access a path outside the authorized folders or when a project permissions
/// policy is set to `ask`.
public struct PermissionRequest: Identifiable, Sendable {
    public let id: UUID
    public let toolName: String
    public let path: String?
    public let requestedRoot: String?
    public let kind: PermissionKind
    public let agentName: String?

    public init(
        id: UUID = UUID(),
        toolName: String,
        path: String? = nil,
        requestedRoot: String? = nil,
        kind: PermissionKind,
        agentName: String? = nil
    ) {
        self.id = id
        self.toolName = toolName
        self.path = path
        self.requestedRoot = requestedRoot
        self.kind = kind
        self.agentName = agentName
    }
}
