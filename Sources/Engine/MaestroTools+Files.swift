import Foundation
import MLXLMCommon

// MARK: - Native file tools
//
// In-process file access that ENFORCES the Settings → Context authorized-folders
// allowlist (the same list the Context tab writes). These back the file tools the
// system prompt advertises, so a self-contained build (no MCP file server) can
// still read/write within folders the user explicitly authorized. Shell execution
// is intentionally NOT provided in the default beta build.
extension MaestroTools {

    static let fileToolNames: Set<String> = ["read_file", "write_file", "list_dir"]

    /// Cap on a single read so a huge file can't blow up the model's context.
    private static let maxReadBytes = 256 * 1024

    static var fileToolSpecs: [ToolSpec] {
        [
            rawSpec("read_file",
                "Read a UTF-8 text file. Use an absolute path. "
                + "Your working directory is automatically authorized for reading.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file."],
                ], required: ["path"]),
            rawSpec("write_file",
                "Create or overwrite a UTF-8 text file. Use an absolute path. "
                + "Your working directory is automatically authorized for writing.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file."],
                    "content": ["type": "string", "description": "The full text to write."],
                ], required: ["path", "content"]),
            rawSpec("list_dir",
                "List the entries of a directory. Use an absolute path. "
                + "Your working directory is automatically authorized for listing.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the directory."],
                ], required: ["path"]),
        ]
    }

    private struct ReadFileArgs: Codable { let path: String? }
    private struct WriteFileArgs: Codable { let path: String?; let content: String? }
    private struct ListDirArgs: Codable { let path: String? }

    /// Enabled authorized roots from Settings → Context, standardized to absolute
    /// paths. A target path is permitted only if it equals one of these roots or
    /// is nested inside one. The agent's working directory is always an implicit
    /// root so the agent can create/edit files under it without manual setup.
    private static func authorizedRoots() -> [String] {
        var roots = SwiftMaestroSettingsStore.loadAuthorizedFolders()
            .filter { $0.enabled }
            .map { URL(fileURLWithPath: ($0.path as NSString).expandingTildeInPath).standardizedFileURL.path }
            .filter { !$0.isEmpty }
        if let wd = workingDirectory, !wd.isEmpty {
            let standardized = URL(fileURLWithPath: wd).standardizedFileURL.path
            if !roots.contains(standardized) {
                roots.append(standardized)
            }
        }
        return roots
    }

    /// Resolve to an absolute, standardized path, or nil if it is not absolute.
    private static func resolveAbsolute(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func isAllowed(_ resolved: String, roots: [String]) -> Bool {
        for root in roots where resolved == root || resolved.hasPrefix(root + "/") {
            return true
        }
        return false
    }

    private static func denied(_ path: String) -> String {
        let roots = authorizedRoots()
        let list = roots.isEmpty ? "(none configured)" : roots.joined(separator: ", ")
        return errorJSON(
            "access denied: '\(path)' is outside the authorized folders. "
            + "Authorized: \(list). Add it in Settings → Context.")
    }

    static func readFile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadFileArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("read_file requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("read_file requires an absolute path (got '\(raw)')")
        }
        let roots = authorizedRoots()
        NSLog("[READ_FILE] path='\(raw)' resolved='\(resolved)' roots=\(roots)")
        guard isAllowed(resolved, roots: roots) else {
            NSLog("[READ_FILE] DENIED: '\(resolved)' not in roots \(roots)")
            return denied(raw)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
            return errorJSON("no file at '\(resolved)'")
        }
        guard let data = FileManager.default.contents(atPath: resolved) else {
            return errorJSON("could not read '\(resolved)'")
        }
        guard data.count <= maxReadBytes else {
            return errorJSON("file too large (\(data.count) bytes; limit \(maxReadBytes)).")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return errorJSON("'\(resolved)' is not UTF-8 text")
        }
        return text
    }

    static func writeFile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WriteFileArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let content = args.content else {
            return errorJSON("write_file requires 'path' and 'content'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("write_file requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let url = URL(fileURLWithPath: resolved)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return jsonString(["status": "written", "path": resolved, "bytes": "\(content.utf8.count)"])
        } catch {
            return errorJSON("failed to write '\(resolved)': \(error.localizedDescription)")
        }
    }

    static func listDir(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ListDirArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("list_dir requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("list_dir requires an absolute path (got '\(raw)')")
        }
        let roots = authorizedRoots()
        NSLog("[LIST_DIR] path='\(raw)' resolved='\(resolved)' roots=\(roots)")
        guard isAllowed(resolved, roots: roots) else {
            NSLog("[LIST_DIR] DENIED: '\(resolved)' not in roots \(roots)")
            return denied(raw)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return errorJSON("no directory at '\(resolved)'")
        }
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: resolved).sorted()
            guard !items.isEmpty else { return "(empty directory) \(resolved)" }
            let lines = items.map { name -> String in
                var sub: ObjCBool = false
                _ = FileManager.default.fileExists(
                    atPath: (resolved as NSString).appendingPathComponent(name), isDirectory: &sub)
                return sub.boolValue ? "\(name)/" : name
            }
            return "Contents of \(resolved) (\(items.count)):\n" + lines.joined(separator: "\n")
        } catch {
            return errorJSON("failed to list '\(resolved)': \(error.localizedDescription)")
        }
    }
}
