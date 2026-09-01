import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - OpenCode-style permission framework
//
// Reads a permissions policy file (e.g. .opencode/permissions.json) from the
// project working directory and enforces allow/ask/deny rules for tools,
// shell commands, and file paths.

public enum PermissionLevel: String, Codable, Sendable, CaseIterable {
    case allow
    case ask
    case deny
}

public struct ToolPermissionRule: Codable, Sendable, Hashable {
    public let tool: String
    public let level: PermissionLevel
    public let reason: String?

    public init(tool: String, level: PermissionLevel, reason: String? = nil) {
        self.tool = tool
        self.level = level
        self.reason = reason
    }
}

public struct PathPermissionRule: Codable, Sendable, Hashable {
    public let path: String
    public let level: PermissionLevel
    public let reason: String?

    public init(path: String, level: PermissionLevel, reason: String? = nil) {
        self.path = path
        self.level = level
        self.reason = reason
    }
}

public struct ShellPermissionRule: Codable, Sendable, Hashable {
    public let pattern: String
    public let level: PermissionLevel
    public let reason: String?

    public init(pattern: String, level: PermissionLevel, reason: String? = nil) {
        self.pattern = pattern
        self.level = level
        self.reason = reason
    }
}

public struct PermissionPolicy: Codable, Sendable, Hashable {
    public let defaultToolLevel: PermissionLevel
    public let defaultPathLevel: PermissionLevel
    public let defaultShellLevel: PermissionLevel
    public let tools: [ToolPermissionRule]
    public let paths: [PathPermissionRule]
    public let shell: [ShellPermissionRule]

    public init(
        defaultToolLevel: PermissionLevel = .allow,
        defaultPathLevel: PermissionLevel = .ask,
        defaultShellLevel: PermissionLevel = .ask,
        tools: [ToolPermissionRule] = [],
        paths: [PathPermissionRule] = [],
        shell: [ShellPermissionRule] = []
    ) {
        self.defaultToolLevel = defaultToolLevel
        self.defaultPathLevel = defaultPathLevel
        self.defaultShellLevel = defaultShellLevel
        self.tools = tools
        self.paths = paths
        self.shell = shell
    }
}

/// Loads and caches permission policies from project working directories.
public final class PermissionService: ToolPermissionChecker, @unchecked Sendable {
    public static let shared = PermissionService()

    public static let permissionFilenames = ["permissions.json", "permissions.jsonc"]
    public static let permissionDirectoryNames = [".opencode", ".ai-context"]

    /// Master enable switch. When disabled, all permission checks are bypassed.
    public var enabled: Bool = true

    /// Per-directory policies, keyed by normalized working directory.
    private var policies: [String: PermissionPolicy] = [:]
    private var fileModifiedDates: [String: Date] = [:]
    private let lock = NSLock()

    private init() {}

    /// Load a policy for the given working directory if a permissions file exists.
    /// Uses a cache unless the file modification date has changed.
    public func policy(forWorkingDirectory directory: String) -> PermissionPolicy? {
        guard let path = Self.permissionFilePath(for: directory) else { return nil }
        let normalized = Self.normalize(directory)

        lock.lock()
        let cached = policies[normalized]
        let cachedModified = fileModifiedDates[path]
        lock.unlock()

        if let cachedModified,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           let currentModified = attributes[.modificationDate] as? Date,
           currentModified == cachedModified,
           let cached {
            return cached
        }

        guard let policy = Self.loadPolicy(from: path) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let modified = attributes?[.modificationDate] as? Date ?? Date()
        lock.lock()
        policies[normalized] = policy
        fileModifiedDates[path] = modified
        lock.unlock()
        return policy
    }

    /// Force a fresh read of the policy for a directory.
    public func refreshPolicy(forWorkingDirectory directory: String) -> PermissionPolicy? {
        guard let path = Self.permissionFilePath(for: directory) else { return nil }
        lock.lock()
        fileModifiedDates.removeValue(forKey: path)
        policies.removeValue(forKey: Self.normalize(directory))
        lock.unlock()
        return policy(forWorkingDirectory: directory)
    }

    /// Clear all cached policies.
    public func clearCache() {
        lock.lock()
        policies.removeAll()
        fileModifiedDates.removeAll()
        lock.unlock()
    }

    // MARK: - Runtime permission check

    private enum PolicyVerdict {
        case allow
        case deny(String)
        case ask
        case noPolicy
    }

    /// Check a tool call against the active project policy and the user's
    /// authorized-folder allowlist. If access is allowed, returns `nil`. If it
    /// is denied, returns a JSON error string. If it requires approval, this
    /// method suspends and shows the permission dock; the user can choose Deny,
    /// Allow once, or Allow always.
    public func checkPermission(for toolName: String, call: ToolCall) async -> String? {
        guard enabled else { return nil }

        let path = Self.extractPath(from: call)
        let policyVerdict = await evaluatePolicy(toolName: toolName, path: path, call: call)

        switch policyVerdict {
        case .allow:
            return nil
        case .deny(let error):
            return error
        case .ask:
            return await askForAccess(
                toolName: toolName,
                path: path.map(Self.normalizePath),
                call: call
            )
        case .noPolicy:
            let normalizedPath = path.map(Self.normalizePath)
            let roots = MaestroTools.authorizedRoots()
            let pathAllowed = normalizedPath.map { MaestroTools.isAllowed($0, roots: roots) } ?? true
            guard !pathAllowed else { return nil }
            return await askForAccess(
                toolName: toolName,
                path: normalizedPath,
                call: call
            )
        }
    }

    // MARK: - Policy evaluation

    private func evaluatePolicy(
        toolName: String,
        path: String?,
        call: ToolCall
    ) async -> PolicyVerdict {
        guard let directory = workingDirectoryForToolCall(call),
              let policy = policy(forWorkingDirectory: directory) else {
            return .noPolicy
        }

        // 1. Tool-level rule
        let toolLevel = policy.tools.first(where: { $0.tool == toolName })?.level
            ?? policy.defaultToolLevel

        switch toolLevel {
        case .deny:
            let reason = policy.tools.first(where: { $0.tool == toolName })?.reason
            return .deny(Self.errorJSON(toolName, reason: reason, "Tool `\(toolName)` is denied by project permissions."))
        case .ask:
            return .ask
        case .allow:
            break
        }

        // 2. Path-level rule for file tools
        guard let path else { return .allow }
        let normalizedPath = Self.normalizePath(path)
        let pathLevel = policy.paths.first { rule in
            normalizedPath.hasPrefix(Self.normalizePath(rule.path))
        }?.level ?? policy.defaultPathLevel

        switch pathLevel {
        case .allow:
            return .allow
        case .deny:
            return .deny(Self.errorJSON(toolName, "Path `\(path)` is denied by project permissions."))
        case .ask:
            return .ask
        }
    }

    // MARK: - User-facing ask flow

    private func askForAccess(
        toolName: String,
        path: String?,
        call: ToolCall
    ) async -> String? {
        let roots = MaestroTools.authorizedRoots()
        let needsFolderAccess = path.map { !MaestroTools.isAllowed($0, roots: roots) } ?? false
        let requestedRoot = path.map { Self.requestedRoot(for: toolName, path: $0) }
        let kind: PermissionKind = needsFolderAccess ? Self.permissionKind(for: toolName) : .tool

        let request = PermissionRequest(
            toolName: toolName,
            path: path,
            requestedRoot: requestedRoot,
            kind: kind
        )

        let decision = await PermissionRequestStore.shared.request(request)

        switch decision {
        case .deny:
            let target = path ?? toolName
            return Self.errorJSON(toolName, "Access to `\(target)` was denied by user.")
        case .allowOnce:
            if let root = requestedRoot {
                MaestroTools.addSessionAuthorizedRoot(root)
            }
            return nil
        case .allowAlways:
            if let root = requestedRoot {
                Self.addAuthorizedFolder(root)
                MaestroTools.addSessionAuthorizedRoot(root)
            }
            await ToolApprovalCache.shared.approve(tool: toolName, call: call)
            if let path {
                await ToolApprovalCache.shared.approve(path: path)
            }
            return nil
        }
    }

    // MARK: - Helpers

    /// The folder that should be added to the authorized list when the user
    /// chooses "Allow always".
    private static func requestedRoot(for toolName: String, path: String) -> String {
        let standardized = Self.normalizePath(path)
        switch toolName {
        case "list_dir":
            return standardized
        case "create_directory":
            let parent = (standardized as NSString).deletingLastPathComponent
            return parent.isEmpty ? standardized : parent
        default:
            let parent = (standardized as NSString).deletingLastPathComponent
            return parent.isEmpty ? standardized : parent
        }
    }

    private static func permissionKind(for toolName: String) -> PermissionKind {
        switch toolName {
        case "read_file", "ocr_image": return .fileRead
        case "write_file": return .fileWrite
        case "list_dir": return .directoryList
        case "create_directory": return .directoryCreate
        case "delete_file": return .fileDelete
        case "copy_file": return .fileCopy
        case "move_file": return .fileMove
        default: return .externalDirectory
        }
    }

    private static func addAuthorizedFolder(_ path: String) {
        let standardized = Self.normalizePath(path)
        var folders = SwiftMaestroSettingsStore.loadAuthorizedFolders()
        guard !folders.contains(where: { Self.normalizePath($0.path) == standardized }) else { return }
        folders.append(AuthorizedFolder(path: standardized, enabled: true))
        SwiftMaestroSettingsStore.saveAuthorizedFolders(folders)
    }

    /// Normalize a path for consistent comparison.
    public static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    // MARK: - Helpers

    /// Locate the permissions file in the working directory, checking
    /// .opencode/permissions.json and .ai-context/permissions.json in order.
    public static func permissionFilePath(for directory: String) -> String? {
        let fm = FileManager.default
        for dirName in permissionDirectoryNames {
            for fileName in permissionFilenames {
                let path = ((directory as NSString).appendingPathComponent(dirName) as NSString)
                    .appendingPathComponent(fileName)
                if fm.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    public static func loadPolicy(from path: String) -> PermissionPolicy? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let policy = try? decoder.decode(PermissionPolicy.self, from: data) {
            return policy
        }
        // Fallback: try parsing as JSONC (strip comments)
        if let raw = String(data: data, encoding: .utf8) {
            let stripped = stripJSONCComments(raw)
            return try? decoder.decode(PermissionPolicy.self, from: Data(stripped.utf8))
        }
        return nil
    }

    private static func stripJSONCComments(_ raw: String) -> String {
        var result: [Character] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(after: index)
            if raw[index] == "/" && next < raw.endIndex {
                if raw[next] == "/" {
                    while index < raw.endIndex && raw[index] != "\n" {
                        index = raw.index(after: index)
                    }
                    continue
                } else if raw[next] == "*" {
                    index = raw.index(after: next)
                    while index < raw.endIndex {
                        let after = raw.index(after: index)
                        if raw[index] == "*" && after < raw.endIndex && raw[after] == "/" {
                            index = raw.index(after: after)
                            break
                        }
                        index = raw.index(after: index)
                    }
                    continue
                }
            }
            result.append(raw[index])
            index = raw.index(after: index)
        }
        return String(result)
    }

    private static func extractPath(from call: ToolCall) -> String? {
        // Best-effort path extraction for common file tools.
        let args = call.function.arguments
        let candidates = ["path", "file_path", "filepath", "directory", "dir", "cwd", "target_path", "source_path", "to"]
        for key in candidates {
            if case .string(let path) = args[key], !path.isEmpty {
                return path
            }
        }
        return nil
    }

    private static func normalize(_ directory: String) -> String {
        URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private static func errorJSON(_ toolName: String, reason: String? = nil, _ message: String) -> String {
        var parts: [String] = [
            "\"error\": \"\(message.escapedForJSON)\"",
            "\"tool\": \"\(toolName.escapedForJSON)\"",
        ]
        if let reason {
            parts.append("\"reason\": \"\(reason.escapedForJSON)\"")
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    private static func pendingJSON(_ toolName: String, _ message: String) -> String {
        return "{"
            + "\"error\": \"\(message.escapedForJSON)\","
            + "\"tool\": \"\(toolName.escapedForJSON)\","
            + "\"permission\": \"ask\""
            + "}"
    }
}

// MARK: - Working directory resolution

private func workingDirectoryForToolCall(_ call: ToolCall) -> String? {
    // The active project directory is not globally available. Use the cwd from
    // the tool call arguments; if missing, no project-specific policy applies.
    if case .string(let cwd) = call.function.arguments["cwd"], !cwd.isEmpty {
        return cwd
    }
    return nil
}

// MARK: - Approval cache

/// In-memory cache of user-approved tool/path access. Real UI integration
/// would replace this with a proper approval store.
public actor ToolApprovalCache {
    public static let shared = ToolApprovalCache()

    private var approvedToolCalls: Set<ToolCall> = []
    private var approvedPaths: Set<String> = []

    public func isApproved(tool: String, call: ToolCall) -> Bool {
        approvedToolCalls.contains(call)
    }

    public func isApproved(path: String) -> Bool {
        approvedPaths.contains(PermissionService.normalizePath(path))
    }

    public func approve(tool: String, call: ToolCall) {
        approvedToolCalls.insert(call)
    }

    public func approve(path: String) {
        approvedPaths.insert(PermissionService.normalizePath(path))
    }

    public func revoke(tool: String, call: ToolCall) {
        approvedToolCalls.remove(call)
    }

    public func revoke(path: String) {
        approvedPaths.remove(PermissionService.normalizePath(path))
    }

    public func clear() {
        approvedToolCalls.removeAll()
        approvedPaths.removeAll()
    }
}

private extension String {
    var escapedForJSON: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
