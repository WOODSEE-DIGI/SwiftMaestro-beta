import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native xattr tools
//
// Read/write macOS extended attributes on any file or directory. Includes
// conveniences for Finder comments and MaestroDAM metadata, while also
// exposing the raw namespace so agents can use arbitrary xattr keys.

extension MaestroTools {

    static func registerXAttrTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "list_xattr", spec: xattrToolSpecs[0],
                category: ToolCategory.file.rawValue,
                handler: { call in await listXAttr(call) }),
            ToolDefinition(
                name: "read_xattr", spec: xattrToolSpecs[1],
                category: ToolCategory.file.rawValue,
                handler: { call in await readXAttr(call) }),
            ToolDefinition(
                name: "write_xattr", spec: xattrToolSpecs[2],
                category: ToolCategory.file.rawValue,
                handler: { call in await writeXAttr(call) }),
            ToolDefinition(
                name: "remove_xattr", spec: xattrToolSpecs[3],
                category: ToolCategory.file.rawValue,
                handler: { call in await removeXAttr(call) }),
            ToolDefinition(
                name: "read_finder_comment", spec: xattrToolSpecs[4],
                category: ToolCategory.file.rawValue,
                handler: { call in await readFinderComment(call) }),
            ToolDefinition(
                name: "write_finder_comment", spec: xattrToolSpecs[5],
                category: ToolCategory.file.rawValue,
                handler: { call in await writeFinderComment(call) }),
        ])
    }

    static var xattrToolSpecs: [ToolSpec] {
        [
            rawSpec("list_xattr",
                "List every extended-attribute name on a file or directory. "
                + "Use this to discover metadata (including Finder tags/comments) "
                + "before reading or writing specific attributes.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file or directory."],
                ], required: ["path"]),
            rawSpec("read_xattr",
                "Read a named extended attribute. Returns the value as UTF-8 text "
                + "when possible, otherwise as base64 data with the detected MIME hint.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file or directory."],
                    "name": ["type": "string", "description": "Attribute name, e.g. com.apple.metadata:kMDItemFinderComment or com.woodseedigi.SwiftMaestro.DAM.description."],
                ], required: ["path", "name"]),
            rawSpec("write_xattr",
                "Set a named extended attribute on a file or directory. Replaces "
                + "any existing value of the same name. Use write_finder_comment "
                + "instead for Finder Get Info comments (it stores the correct "
                + "binary plist format).",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file or directory."],
                    "name": ["type": "string", "description": "Attribute name. Use reverse-DNS style to avoid collisions."],
                    "value": ["type": "string", "description": "Value to store. Text by default; provide base64 and set encoding='base64' for arbitrary binary data."],
                    "encoding": ["type": "string", "description": "Encoding of 'value': 'utf8' (default) or 'base64'."],
                ], required: ["path", "name", "value"]),
            rawSpec("remove_xattr",
                "Delete a named extended attribute from a file or directory. "
                + "This is a destructive operation — ask the user before removing "
                + "attributes you did not create.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file or directory."],
                    "name": ["type": "string", "description": "Attribute name to remove."],
                ], required: ["path", "name"]),
            rawSpec("read_finder_comment",
                "Read the Finder Get Info comment (the comment shown in Finder's "
                + "Inspector and on icon hover), if one exists.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file or directory."],
                ], required: ["path"]),
            rawSpec("write_finder_comment",
                "Set the Finder Get Info comment for a file or directory. The "
                + "comment is stored in the same binary-plist format Finder uses, "
                + "so it is visible in Finder immediately.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file or directory."],
                    "comment": ["type": "string", "description": "Comment text. Empty string clears the comment."],
                ], required: ["path", "comment"]),
        ]
    }

    // MARK: - Arguments

    private struct ListXAttrArgs: Codable { let path: String? }
    private struct ReadXAttrArgs: Codable { let path, name: String? }
    private struct WriteXAttrArgs: Codable {
        let path, name, value, encoding: String?
    }
    private struct RemoveXAttrArgs: Codable { let path, name: String? }
    private struct ReadFinderCommentArgs: Codable { let path: String? }
    private struct WriteFinderCommentArgs: Codable { let path, comment: String? }

    // MARK: - Handlers

    private static func listXAttr(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ListXAttrArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("list_xattr requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("list_xattr requires an absolute path (got '\(raw)')")
        }
        if !isAllowed(resolved, roots: authorizedRoots()) {
            if let accessError = await requestFolderAccess(toolName: "list_xattr", path: raw, call: call) {
                return accessError
            }
        }
        let actualPath = fuzzyResolve(resolved, wantDirectory: true)
            ?? fuzzyResolve(resolved, wantDirectory: false)
            ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath) else {
            return errorJSON("no file or directory at '\(resolved)'.")
        }
        do {
            let names = try XAttrService.list(at: URL(fileURLWithPath: actualPath))
            return jsonString(["path": actualPath, "attributes": names])
        } catch {
            return errorJSON("failed to list xattrs for '\(actualPath)': \(error.localizedDescription)")
        }
    }

    private static func readXAttr(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadXAttrArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return errorJSON("read_xattr requires 'path' and 'name'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("read_xattr requires an absolute path (got '\(raw)')")
        }
        if !isAllowed(resolved, roots: authorizedRoots()) {
            if let accessError = await requestFolderAccess(toolName: "read_xattr", path: raw, call: call) {
                return accessError
            }
        }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath) else {
            return errorJSON("no file or directory at '\(resolved)'.")
        }
        do {
            let data = try XAttrService.read(at: URL(fileURLWithPath: actualPath), name: name)
            if let text = String(data: data, encoding: .utf8) {
                return jsonString(["path": actualPath, "name": name, "type": "text", "value": text])
            }
            return jsonString([
                "path": actualPath,
                "name": name,
                "type": "binary",
                "size_bytes": data.count,
                "base64": data.base64EncodedString(),
            ])
        } catch {
            return errorJSON("failed to read xattr '\(name)' for '\(actualPath)': \(error.localizedDescription)")
        }
    }

    private static func writeXAttr(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WriteXAttrArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let value = args.value else {
            return errorJSON("write_xattr requires 'path', 'name', and 'value'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("write_xattr requires an absolute path (got '\(raw)')")
        }
        if !isAllowed(resolved, roots: authorizedRoots()) {
            if let accessError = await requestFolderAccess(toolName: "write_xattr", path: raw, call: call) {
                return accessError
            }
        }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath) else {
            return errorJSON("no file or directory at '\(resolved)'.")
        }

        let encoding = args.encoding?.lowercased() ?? "utf8"
        let data: Data
        if encoding == "base64" {
            guard let decoded = Data(base64Encoded: value, options: .ignoreUnknownCharacters) else {
                return errorJSON("write_xattr could not decode value as base64")
            }
            data = decoded
        } else {
            guard let utf8 = value.data(using: .utf8) else {
                return errorJSON("write_xattr could not encode value as UTF-8")
            }
            data = utf8
        }

        do {
            try XAttrService.write(at: URL(fileURLWithPath: actualPath), name: name, data: data)
            return jsonString(["status": "ok", "path": actualPath, "name": name, "bytes": data.count])
        } catch {
            return errorJSON("failed to write xattr '\(name)' for '\(actualPath)': \(error.localizedDescription)")
        }
    }

    private static func removeXAttr(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: RemoveXAttrArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return errorJSON("remove_xattr requires 'path' and 'name'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("remove_xattr requires an absolute path (got '\(raw)')")
        }
        if !isAllowed(resolved, roots: authorizedRoots()) {
            if let accessError = await requestFolderAccess(toolName: "remove_xattr", path: raw, call: call) {
                return accessError
            }
        }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath) else {
            return errorJSON("no file or directory at '\(resolved)'.")
        }
        do {
            try XAttrService.remove(at: URL(fileURLWithPath: actualPath), name: name)
            return jsonString(["status": "removed", "path": actualPath, "name": name])
        } catch {
            return errorJSON("failed to remove xattr '\(name)' from '\(actualPath)': \(error.localizedDescription)")
        }
    }

    private static func readFinderComment(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadFinderCommentArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("read_finder_comment requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("read_finder_comment requires an absolute path (got '\(raw)')")
        }
        if !isAllowed(resolved, roots: authorizedRoots()) {
            if let accessError = await requestFolderAccess(toolName: "read_finder_comment", path: raw, call: call) {
                return accessError
            }
        }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath) else {
            return errorJSON("no file or directory at '\(resolved)'.")
        }
        do {
            let comment = try XAttrService.finderComment(at: URL(fileURLWithPath: actualPath))
            return jsonString(["path": actualPath, "comment": comment ?? ""])
        } catch {
            return errorJSON("failed to read Finder comment for '\(actualPath)': \(error.localizedDescription)")
        }
    }

    private static func writeFinderComment(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WriteFinderCommentArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let comment = args.comment else {
            return errorJSON("write_finder_comment requires 'path' and 'comment'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("write_finder_comment requires an absolute path (got '\(raw)')")
        }
        if !isAllowed(resolved, roots: authorizedRoots()) {
            if let accessError = await requestFolderAccess(toolName: "write_finder_comment", path: raw, call: call) {
                return accessError
            }
        }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath) else {
            return errorJSON("no file or directory at '\(resolved)'.")
        }
        do {
            try XAttrService.setFinderComment(at: URL(fileURLWithPath: actualPath), comment: comment)
            return jsonString(["status": "ok", "path": actualPath, "comment": comment])
        } catch {
            return errorJSON("failed to write Finder comment for '\(actualPath)': \(error.localizedDescription)")
        }
    }
}
