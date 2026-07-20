import Foundation
import MLXLMCommon

// MARK: - Obsidian Tool Provider
//
// Native Swift implementation of Obsidian vault tools — the same tools
// previously served by the ai-context-bridge MCP server, but now as a
// built-in tool plugin. This means Obsidian access works out of the box
// for any SwiftMaestro install with a vault under ~/Obsidian, with no
// MCP server required.
//
// Two categories of tools:
// 1. File-based (vault read/write) — direct FileManager access to ~/Obsidian
// 2. REST API — calls the Obsidian Local REST API plugin (port 27124)

struct ObsidianToolProvider: ToolProvider {
    let id = "obsidian"

    func provideTools() async -> [ToolProviderTool] {
        [
            ToolProviderTool(
                name: "search_vault",
                spec: Self.specs[0],
                category: .vault,
                handler: { call in await Self.searchVault(call) }),
            ToolProviderTool(
                name: "read_note",
                spec: Self.specs[1],
                category: .vault,
                handler: { call in await Self.readNote(call) }),
            ToolProviderTool(
                name: "write_note",
                spec: Self.specs[2],
                category: .vault,
                handler: { call in await Self.writeNote(call) }),
            ToolProviderTool(
                name: "list_vault",
                spec: Self.specs[3],
                category: .vault,
                handler: { call in await Self.listVault(call) }),
        ]
    }

    // MARK: - Vault Root

    private static let vaultRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Obsidian")
    }()

    // MARK: - Tool Specs

    static let specs: [ToolSpec] = [
        MaestroTools.rawSpec(
            "search_vault",
            "Full-text search across all Obsidian vault notes. Returns matching lines with file paths and line numbers.",
            properties: [
                "query": ["type": "string", "description": "Search query string"],
                "max_results": ["type": "integer", "description": "Max results to return (default 20)"],
            ],
            required: ["query"]),
        MaestroTools.rawSpec(
            "read_note",
            "Read a note from the Obsidian vault. Returns the full markdown content.",
            properties: [
                "filepath": ["type": "string", "description": "Vault-relative path (e.g. 'Tech Configs/Network Settings/router.md') or absolute path under ~/Obsidian"],
            ],
            required: ["filepath"]),
        MaestroTools.rawSpec(
            "write_note",
            "Create, overwrite, or append a note in any Obsidian vault under ~/Obsidian. "
            + "Parent folders are created automatically. Obsidian picks up changes live.",
            properties: [
                "filepath": ["type": "string", "description": "Vault-relative path (e.g. 'OSINTIAN/Notes/foo.md')"],
                "content": ["type": "string", "description": "Content to write"],
                "append": ["type": "boolean", "description": "Append instead of overwrite (default false)"],
            ],
            required: ["filepath", "content"]),
        MaestroTools.rawSpec(
            "list_vault",
            "List notes and folders in the Obsidian vault. Returns a directory listing with [DIR] and [FILE] prefixes.",
            properties: [
                "subfolder": ["type": "string", "description": "Subfolder to list (default: vault root)"],
                "depth": ["type": "integer", "description": "Max directory depth (default 1)"],
            ],
            required: []),
    ]

    // MARK: - Tool Implementations

    private static func searchVault(_ call: ToolCall) async -> String {
        let args = Self.decodeArgs(call)
        guard let query = args["query"] as? String, !query.isEmpty else {
            return MaestroTools.errorJSON("query is required")
        }
        let maxResults = args["max_results"] as? Int ?? 20
        let queryLower = query.lowercased()

        var matches: [String] = []
        let fm = FileManager.default

        func searchDir(_ dir: URL) {
            guard matches.count < maxResults else { return }
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for item in items {
                guard matches.count < maxResults else { return }
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }

                var isDir: ObjCBool = false
                fm.fileExists(atPath: item.path, isDirectory: &isDir)
                if isDir.boolValue {
                    searchDir(item)
                    continue
                }
                guard name.hasSuffix(".md") else { continue }
                guard let content = try? String(contentsOf: item, encoding: .utf8) else { continue }

                let lines = content.components(separatedBy: .newlines)
                for (i, line) in lines.enumerated() {
                    guard matches.count < maxResults else { return }
                    if line.lowercased().contains(queryLower) {
                        let start = max(0, i - 1)
                        let end = min(lines.count, i + 3)
                        let context = lines[start..<end].joined(separator: "\n")
                        let relPath = item.path.replacingOccurrences(
                            of: vaultRoot.path + "/", with: "")
                        matches.append("--- \(relPath) (line \(i + 1)) ---\n\(context)")
                    }
                }
            }
        }

        searchDir(vaultRoot)
        if matches.isEmpty {
            return "No results for \"\(query)\"."
        }
        return "\(matches.count) result(s):\n\n" + matches.joined(separator: "\n\n")
    }

    private static func readNote(_ call: ToolCall) async -> String {
        let args = Self.decodeArgs(call)
        guard let filepath = args["filepath"] as? String, !filepath.isEmpty else {
            return MaestroTools.errorJSON("filepath is required")
        }

        let url: URL
        if filepath.hasPrefix("/") {
            url = URL(fileURLWithPath: filepath)
        } else {
            url = vaultRoot.appendingPathComponent(filepath)
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Not found: \(url.path)"
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return MaestroTools.errorJSON("Failed to read \(filepath)")
        }
        return content
    }

    private static func writeNote(_ call: ToolCall) async -> String {
        let args = Self.decodeArgs(call)
        guard let filepath = args["filepath"] as? String, !filepath.isEmpty else {
            return MaestroTools.errorJSON("filepath is required")
        }
        let content = args["content"] as? String ?? ""
        let append = args["append"] as? Bool ?? false

        let url: URL
        if filepath.hasPrefix("/") {
            url = URL(fileURLWithPath: filepath)
        } else {
            url = vaultRoot.appendingPathComponent(filepath)
        }

        // Safety: confine writes to the Obsidian root.
        let resolved = url.standardized
        let vaultRootStd = vaultRoot.standardized
        guard resolved.path == vaultRootStd.path || resolved.path.hasPrefix(vaultRootStd.path + "/") else {
            return MaestroTools.errorJSON("Refused: path escapes the Obsidian root (\(vaultRoot.path))")
        }

        // Create parent directories.
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if append {
            guard let fh = FileHandle(forWritingAtPath: url.path) else {
                // File doesn't exist yet, create it.
                guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else {
                    return MaestroTools.errorJSON("Failed to create \(filepath)")
                }
                return MaestroTools.jsonString(["result": "Created and wrote \(content.utf8.count) bytes to \(filepath)"])
            }
            fh.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                fh.write(data)
            }
            fh.closeFile()
            return MaestroTools.jsonString(["result": "Appended \(content.utf8.count) bytes to \(filepath)"])
        } else {
            guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else {
                return MaestroTools.errorJSON("Failed to write \(filepath)")
            }
            return MaestroTools.jsonString(["result": "Wrote \(content.utf8.count) bytes to \(filepath)"])
        }
    }

    private static func listVault(_ call: ToolCall) async -> String {
        let args = Self.decodeArgs(call)
        let subfolder = args["subfolder"] as? String
        let maxDepth = args["depth"] as? Int ?? 1

        let base: URL
        if let subfolder {
            base = vaultRoot.appendingPathComponent(subfolder)
        } else {
            base = vaultRoot
        }

        var results: [String] = []
        let fm = FileManager.default

        func walk(dir: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".") { continue }
                let relPath = item.path.replacingOccurrences(of: vaultRoot.path + "/", with: "")

                var isDir: ObjCBool = false
                fm.fileExists(atPath: item.path, isDirectory: &isDir)
                if isDir.boolValue {
                    results.append("[DIR]  \(relPath)/")
                    walk(dir: item, depth: depth + 1)
                } else {
                    results.append("[FILE] \(relPath)")
                }
            }
        }

        walk(dir: base, depth: 1)
        if results.isEmpty {
            return "Empty."
        }
        return "Vault (\(results.count)):\n" + results.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func decodeArgs(_ call: ToolCall) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in call.function.arguments {
            switch value {
            case .string(let s): result[key] = s
            case .int(let n): result[key] = n
            case .double(let n): result[key] = n
            case .bool(let b): result[key] = b
            case .null: result[key] = NSNull()
            case .array(let a): result[key] = a
            case .object(let o): result[key] = o
            }
        }
        return result
    }
}
