import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native coding/IDE tools
//
// Tools that mirror OpenCode's core IDE surface: file discovery (glob),
// content search (grep), precise editing (edit_file), and git operations.
// These run in-process and enforce the same authorized-folder allowlist as
// the file tools.

extension MaestroTools {

    static func registerCodingTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "glob_files", spec: codingToolSpecs[0],
                category: ToolCategory.file.rawValue,
                handler: { call in await globFiles(call) }),
            ToolDefinition(
                name: "grep_code", spec: codingToolSpecs[1],
                category: ToolCategory.file.rawValue,
                handler: { call in await grepCode(call) }),
            ToolDefinition(
                name: "edit_file", spec: codingToolSpecs[2],
                category: ToolCategory.file.rawValue,
                handler: { call in await editFile(call) }),
            ToolDefinition(
                name: "git_status", spec: codingToolSpecs[3],
                category: ToolCategory.shell.rawValue,
                handler: { call in await gitStatus(call) }),
            ToolDefinition(
                name: "git_diff", spec: codingToolSpecs[4],
                category: ToolCategory.shell.rawValue,
                handler: { call in await gitDiff(call) }),
            ToolDefinition(
                name: "git_log", spec: codingToolSpecs[5],
                category: ToolCategory.shell.rawValue,
                handler: { call in await gitLog(call) }),
            ToolDefinition(
                name: "git_branch", spec: codingToolSpecs[6],
                category: ToolCategory.shell.rawValue,
                handler: { call in await gitBranch(call) }),
        ])
    }

    static var codingToolSpecs: [ToolSpec] {
        [
            rawSpec("glob_files",
                "Find files matching a glob pattern within authorized folders. "
                + "Supports * and ** wildcards. Returns absolute paths. "
                + "Use to discover files before reading or editing them.",
                properties: [
                    "pattern": ["type": "string", "description": "Glob pattern such as 'Sources/**/*.swift' or '*.md'."],
                    "path": ["type": "string", "description": "Optional absolute directory to search. Defaults to the working directory or authorized roots."],
                    "limit": ["type": "integer", "description": "Maximum number of matches to return. Default 200."],
                ], required: ["pattern"]),
            rawSpec("grep_code",
                "Search file contents with a regular expression across authorized folders. "
                + "Prefer this over reading many files when looking for symbols, usages, or patterns.",
                properties: [
                    "pattern": ["type": "string", "description": "Regular expression to search for (case-sensitive by default)."],
                    "path": ["type": "string", "description": "Optional absolute directory to search. Defaults to the working directory or authorized roots."],
                    "glob": ["type": "string", "description": "Optional glob filter for files to search, e.g. '*.swift'."],
                    "case_sensitive": ["type": "boolean", "description": "Whether the search is case-sensitive. Default true."],
                    "limit": ["type": "integer", "description": "Maximum matches to return. Default 100."],
                ], required: ["pattern"]),
            rawSpec("edit_file",
                "Make a precise string replacement in a file. The old_string must match exactly, "
                + "including whitespace and newlines. Use this for surgical edits instead of rewriting "
                + "the whole file with write_file. Example: to insert a comment after import lines, "
                + "old_string='import SwiftUI\\nimport SwiftMaestroKit' and "
                + "new_string='import SwiftUI\\nimport SwiftMaestroKit\\n\\n// CodeTester was here'.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file to edit."],
                    "old_string": ["type": "string", "description": "Exact existing text to replace, including whitespace and newlines."],
                    "new_string": ["type": "string", "description": "Text to insert in its place."],
                    "replace_all": ["type": "boolean", "description": "Replace every occurrence instead of just the first. Default false."],
                ], required: ["path", "old_string", "new_string"]),
            rawSpec("git_status",
                "Show git status for the repository at the working directory or a given path.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to a directory inside a git repository. Defaults to working directory."],
                ], required: []),
            rawSpec("git_diff",
                "Show git diff for the repository at the working directory or a given path.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to a directory inside a git repository. Defaults to working directory."],
                    "file": ["type": "string", "description": "Optional file path to limit the diff."],
                    "staged": ["type": "boolean", "description": "Show staged diff instead of unstaged. Default false."],
                ], required: []),
            rawSpec("git_log",
                "Show recent git commit history for the repository at the working directory or a given path.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to a directory inside a git repository. Defaults to working directory."],
                    "limit": ["type": "integer", "description": "Number of commits to show. Default 10."],
                    "file": ["type": "string", "description": "Optional file path to limit history."],
                ], required: []),
            rawSpec("git_branch",
                "List git branches for the repository at the working directory or a given path.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to a directory inside a git repository. Defaults to working directory."],
                ], required: []),
        ]
    }

    // MARK: - Args

    private struct GlobFilesArgs: Codable {
        let pattern: String?
        let path: String?
        let limit: Int?
    }
    private struct GrepCodeArgs: Codable {
        let pattern: String?
        let path: String?
        let glob: String?
        let case_sensitive: Bool?
        let limit: Int?
    }
    private struct EditFileArgs: Codable {
        let path: String?
        let old_string: String?
        let new_string: String?
        let replace_all: Bool?
    }
    private struct GitPathArgs: Codable {
        let path: String?
    }
    private struct GitDiffArgs: Codable {
        let path: String?
        let file: String?
        let staged: Bool?
    }
    private struct GitLogArgs: Codable {
        let path: String?
        let limit: Int?
        let file: String?
    }

    // MARK: - glob_files

    private static func globFiles(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GlobFilesArgs.self),
              let pattern = args.pattern?.trimmingCharacters(in: .whitespaces), !pattern.isEmpty else {
            return errorJSON("glob_files requires 'pattern'")
        }
        let roots = authorizedRoots()
        let explicitPath: String? = {
            guard let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return resolveAbsolute(raw)
        }()
        let searchRoots: [String]
        if let explicitPath = explicitPath {
            guard isAllowed(explicitPath, roots: roots) else {
                return denied(explicitPath)
            }
            searchRoots = [explicitPath]
        } else {
            searchRoots = roots
        }
        let limit = max(1, min(1000, args.limit ?? 200))
        let matcher = GlobMatcher(pattern: pattern)
        var matches: [String] = []
        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard matches.count < limit else { break }
                let relative = url.path.replacingOccurrences(of: root, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if matcher.match(relative) {
                    matches.append(url.path)
                }
            }
            guard matches.count < limit else { break }
        }
        let result: [String: any Sendable] = [
            "count": matches.count,
            "matches": matches,
            "pattern": pattern,
            "roots": searchRoots,
            "truncated": matches.count >= limit,
        ]
        return jsonString(result)
    }

    // MARK: - grep_code

    private static func grepCode(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GrepCodeArgs.self),
              let pattern = args.pattern?.trimmingCharacters(in: .whitespaces), !pattern.isEmpty else {
            return errorJSON("grep_code requires 'pattern'")
        }
        let roots = authorizedRoots()
        let explicitPath: String? = {
            guard let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return resolveAbsolute(raw)
        }()
        let searchRoots: [String]
        if let explicitPath = explicitPath {
            guard isAllowed(explicitPath, roots: roots) else {
                return denied(explicitPath)
            }
            searchRoots = [explicitPath]
        } else {
            searchRoots = roots
        }
        let limit = max(1, min(500, args.limit ?? 100))
        let globFilter = args.glob?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let caseSensitive = args.case_sensitive ?? true
        let matcher: GlobMatcher? = globFilter.map { GlobMatcher(pattern: $0) }
        var regex: NSRegularExpression
        do {
            let options: NSRegularExpression.Options = caseSensitive ? [] : .caseInsensitive
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            return errorJSON("invalid regex: \(error.localizedDescription)")
        }
        let maxBytesPerFile = 2 * 1024 * 1024 // 2 MB
        var results: [[String: any Sendable]] = []
        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                guard results.count < limit else { break }
                let relative = url.path.replacingOccurrences(of: root, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let matcher = matcher, !matcher.match(relative) { continue }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= maxBytesPerFile else { continue }
                guard let text = String(data: data, encoding: .utf8) else { continue }
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches {
                    guard results.count < limit else { break }
                    let lineRange = text.lineRange(for: match.range)
                    let lineNumber = text.lineNumber(at: match.range.location)
                    let snippet = String(text[lineRange]).trimmingCharacters(in: .newlines)
                    results.append([
                        "path": url.path,
                        "line": lineNumber,
                        "match": (text as NSString).substring(with: match.range),
                        "snippet": snippet,
                    ])
                }
            }
            guard results.count < limit else { break }
        }
        let result: [String: any Sendable] = [
            "count": results.count,
            "matches": results,
            "pattern": pattern,
            "case_sensitive": caseSensitive,
            "truncated": results.count >= limit,
        ]
        return jsonString(result)
    }

    // MARK: - edit_file

    private static func editFile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: EditFileArgs.self),
              let rawPath = args.path?.trimmingCharacters(in: .whitespaces), !rawPath.isEmpty,
              let oldString = args.old_string,
              let newString = args.new_string else {
            return errorJSON("edit_file requires 'path', 'old_string', and 'new_string'")
        }
        guard let resolved = resolveAbsolute(rawPath) else {
            return errorJSON("edit_file requires an absolute path")
        }
        let roots = authorizedRoots()
        guard isAllowed(resolved, roots: roots) else {
            return denied(resolved)
        }
        guard let data = FileManager.default.contents(atPath: resolved),
              let original = String(data: data, encoding: .utf8) else {
            return errorJSON("could not read file at \(resolved)")
        }
        let replaceAll = args.replace_all ?? false
        let updated: String
        let count: Int
        if replaceAll {
            let parts = original.components(separatedBy: oldString)
            count = parts.count - 1
            guard count > 0 else {
                return errorJSON("old_string not found in \(resolved)")
            }
            updated = parts.joined(separator: newString)
        } else {
            guard let range = original.range(of: oldString) else {
                return errorJSON("old_string not found in \(resolved)")
            }
            updated = original.replacingCharacters(in: range, with: newString)
            count = 1
        }
        do {
            try updated.write(toFile: resolved, atomically: true, encoding: .utf8)
        } catch {
            return errorJSON("failed to write file: \(error.localizedDescription)")
        }
        let result: [String: any Sendable] = [
            "path": resolved,
            "replacements": count,
            "replace_all": replaceAll,
        ]
        return jsonString(result)
    }

    // MARK: - git helpers

    private static func resolveGitRepoPath(_ rawPath: String?) -> String? {
        guard let raw = rawPath?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return workingDirectory
        }
        return resolveAbsolute(raw)
    }

    private static func runGit(
        arguments: [String],
        repoPath: String?
    ) -> String {
        guard let repoPath = resolveGitRepoPath(repoPath) else {
            return errorJSON("git tool requires a path or working directory")
        }
        let roots = authorizedRoots()
        guard isAllowed(repoPath, roots: roots) else {
            return denied(repoPath)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoPath, isDirectory: &isDir), isDir.boolValue else {
            return errorJSON("path is not a directory: \(repoPath)")
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = arguments
        task.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return errorJSON("failed to run git: \(error.localizedDescription)")
        }
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if task.terminationStatus != 0 {
            return errorJSON("git error: \(err.trimmingCharacters(in: .whitespaces))")
        }
        let result: [String: any Sendable] = [
            "stdout": out,
            "stderr": err,
            "exit_code": task.terminationStatus,
        ]
        return jsonString(result)
    }

    private static func gitStatus(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GitPathArgs.self) else {
            return errorJSON("git_status: failed to decode arguments")
        }
        return runGit(arguments: ["status", "--short", "--branch"], repoPath: args.path)
    }

    private static func gitDiff(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GitDiffArgs.self) else {
            return errorJSON("git_diff: failed to decode arguments")
        }
        var gitArgs = ["diff"]
        if args.staged == true {
            gitArgs.append("--cached")
        }
        if let file = args.file?.trimmingCharacters(in: .whitespaces), !file.isEmpty {
            gitArgs.append(file)
        }
        return runGit(arguments: gitArgs, repoPath: args.path)
    }

    private static func gitLog(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GitLogArgs.self) else {
            return errorJSON("git_log: failed to decode arguments")
        }
        let limit = max(1, min(100, args.limit ?? 10))
        var gitArgs = ["log", "--oneline", "--max-count=\(limit)"]
        if let file = args.file?.trimmingCharacters(in: .whitespaces), !file.isEmpty {
            gitArgs.append("--")
            gitArgs.append(file)
        }
        return runGit(arguments: gitArgs, repoPath: args.path)
    }

    private static func gitBranch(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GitPathArgs.self) else {
            return errorJSON("git_branch: failed to decode arguments")
        }
        return runGit(arguments: ["branch", "-a"], repoPath: args.path)
    }
}

// MARK: - Glob matcher

private struct GlobMatcher {
    private let regex: NSRegularExpression?

    init(pattern: String) {
        let escaped = pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "+", with: "\\+")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "**", with: "\u{0000}")
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "\u{0000}", with: ".*")
            .replacingOccurrences(of: "?", with: "[^/]")
        let anchored = "^\(escaped)$"
        self.regex = try? NSRegularExpression(pattern: anchored, options: [])
    }

    func match(_ path: String) -> Bool {
        guard let regex = regex else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }
}

// MARK: - String helpers for grep

private extension String {
    func lineRange(for nsRange: NSRange) -> Range<String.Index> {
        let start = self.index(self.startIndex, offsetBy: max(0, nsRange.location))
        var end = start
        if let newline = self[start...].firstIndex(where: { $0.isNewline }) {
            end = newline
        } else {
            end = self.endIndex
        }
        var lineStart = start
        if let prevNewline = self[..<start].lastIndex(where: { $0.isNewline }) {
            lineStart = self.index(after: prevNewline)
        }
        return lineStart..<end
    }

    func lineNumber(at location: Int) -> Int {
        let prefix = (self as NSString).substring(to: location)
        return prefix.components(separatedBy: .newlines).count
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension MaestroTools {
    static func jsonString(_ value: [String: any Sendable]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }
}
