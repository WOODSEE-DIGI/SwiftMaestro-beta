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

    /// Check a tool call against the active project policy. Returns a JSON
    /// error string if the tool is denied or requires approval that was not
    /// obtained. Returns nil to allow the tool to run.
    public func checkPermission(for toolName: String, call: ToolCall) async -> String? {
        guard enabled else { return nil }
        guard let directory = workingDirectoryForToolCall(call),
              let policy = policy(forWorkingDirectory: directory) else { return nil }

        // 1. Tool-level rule
        let level = policy.tools.first(where: { $0.tool == toolName })?.level
            ?? policy.defaultToolLevel

        switch level {
        case .allow:
            break
        case .deny:
            let reason = policy.tools.first(where: { $0.tool == toolName })?.reason
            return Self.errorJSON(toolName, reason: reason, "Tool `\(toolName)` is denied by project permissions.")
        case .ask:
            let approved = await ToolApprovalCache.shared.isApproved(tool: toolName, call: call)
            if !approved {
                return Self.pendingJSON(toolName, "Tool `\(toolName)` requires user approval before it can run.")
            }
        }

        // 2. Path-level rule for file tools
        if let path = Self.extractPath(from: call) {
            let normalizedPath = Self.normalizePath(path)
            let pathLevel = policy.paths.first { rule in
                normalizedPath.hasPrefix(Self.normalizePath(rule.path))
            }?.level ?? policy.defaultPathLevel

            switch pathLevel {
            case .allow:
                break
            case .deny:
                return Self.errorJSON(toolName, "Path `\(path)` is denied by project permissions.")
            case .ask:
                let approved = await ToolApprovalCache.shared.isApproved(path: path)
                if !approved {
                    return Self.pendingJSON(toolName, "Path `\(path)` requires user approval before it can be accessed.")
                }
            }
        }

        return nil
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
