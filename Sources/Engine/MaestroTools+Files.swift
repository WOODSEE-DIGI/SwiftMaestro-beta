import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native file tools
//
// In-process file access that ENFORCES the Settings → Context authorized-folders
// allowlist (the same list the Context tab writes). These back the file tools the
// system prompt advertises, so a self-contained build (no MCP file server) can
// still read/write within folders the user explicitly authorized. Shell execution
// is intentionally NOT provided in the default beta build.
extension MaestroTools {

    static func registerFileTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "read_file", spec: fileToolSpecs[0],
                category: ToolCategory.file.rawValue,
                handler: { call in await readFile(call) }),
            ToolDefinition(
                name: "write_file", spec: fileToolSpecs[1],
                category: ToolCategory.file.rawValue,
                handler: { call in await writeFile(call) }),
            ToolDefinition(
                name: "list_dir", spec: fileToolSpecs[2],
                category: ToolCategory.file.rawValue,
                handler: { call in await listDir(call) }),
            ToolDefinition(
                name: "ocr_image", spec: fileToolSpecs[3],
                category: ToolCategory.file.rawValue,
                handler: { call in await ocrImage(call) }),
            ToolDefinition(
                name: "copy_file", spec: fileToolSpecs[4],
                category: ToolCategory.file.rawValue,
                handler: { call in await copyFile(call) }),
            ToolDefinition(
                name: "move_file", spec: fileToolSpecs[5],
                category: ToolCategory.file.rawValue,
                handler: { call in await moveFile(call) }),
            ToolDefinition(
                name: "delete_file", spec: fileToolSpecs[6],
                category: ToolCategory.file.rawValue,
                handler: { call in await deleteFile(call) }),
            ToolDefinition(
                name: "create_directory", spec: fileToolSpecs[7],
                category: ToolCategory.file.rawValue,
                handler: { call in await createDirectory(call) }),
            ToolDefinition(
                name: "list_file_snapshots", spec: fileToolSpecs[8],
                category: ToolCategory.file.rawValue,
                handler: { call in await listFileSnapshots(call) }),
            ToolDefinition(
                name: "restore_file_snapshot", spec: fileToolSpecs[9],
                category: ToolCategory.file.rawValue,
                handler: { call in await restoreFileSnapshot(call) }),
        ])
    }



    /// Cap on a single read so a huge file can't blow up the model's context.
    private static let maxReadBytes = 256 * 1024
    /// Default character limit for read_file output to keep prompt small.
    private static let defaultReadLimit = 4096

    static var fileToolSpecs: [ToolSpec] {
        [
            rawSpec("read_file",
                "Read any file. Text files return UTF-8 content. Documents "
                + "(.docx, .pdf, .rtf, .odt, .pages, .html) are extracted to plain text. "
                + "Images and other binary files return base64 data with MIME type. "
                + "Use offset (line number) and limit (max lines) for text/document output.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file."],
                    "offset": ["type": "integer", "description": "Start line (1-based). For text/document extraction only. Default 1."],
                    "limit": ["type": "integer", "description": "Max lines to return. For text/document extraction only. Default ~100."],
                ], required: ["path"]),
            rawSpec("write_file",
                "Create or overwrite any file. Default is UTF-8 text. Set encoding='base64' "
                + "and provide base64 content to write binary files (images, PDFs, archives, etc.). "
                + "Set append=true to add content to the end of an existing file instead of replacing it "
                + "(useful for building large files in chunks). "
                + "Your working directory is automatically authorized for writing.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file."],
                    "content": ["type": "string", "description": "The content to write. Text when encoding is utf8 (default); base64 string when encoding is base64."],
                    "encoding": ["type": "string", "description": "Encoding of 'content': 'utf8' (default) or 'base64'."],
                    "append": ["type": "boolean", "description": "If true, append content to the end of the existing file instead of overwriting. Default false."],
                ], required: ["path", "content"]),
            rawSpec("list_dir",
                "List ALL entries (files and subdirectories) of a directory, ONE level only "
                + "(NOT recursive), INCLUDING hidden dotfiles. Use an absolute path. "
                + "Your working directory is automatically authorized for listing. "
                + "IMPORTANT: Return EVERY entry — do NOT filter, skip, or prioritize files you think "
                + "are 'important'. The user needs to see the COMPLETE contents. "
                + "NOTE: the entry count is for ONE level, so it will be much smaller than "
                + "index_directory's RECURSIVE totals for the same path — that difference is "
                + "expected, NOT an error. For large directories, "
                + "prefer index_directory instead — it gives a structured tree with Spotlight metadata "
                + "(file types, sizes, dates) without reading any file contents.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the directory."],
                ], required: ["path"]),
            rawSpec("ocr_image",
                "Extract text from an image file using the vision model. "
                + "Supports PNG, JPEG, HEIC, TIFF, BMP, WebP only — not PDFs.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the image file."],
                ], required: ["path"]),
            rawSpec("copy_file",
                "Copy a file to a new location. Both source and destination must be inside authorized folders.",
                properties: [
                    "source": ["type": "string", "description": "Absolute path to the source file."],
                    "destination": ["type": "string", "description": "Absolute path for the new copy."],
                ], required: ["source", "destination"]),
            rawSpec("move_file",
                "Move or rename a file. Both source and destination must be inside authorized folders.",
                properties: [
                    "source": ["type": "string", "description": "Absolute path to the source file."],
                    "destination": ["type": "string", "description": "Absolute path for the moved file (rename by changing the last component)."],
                ], required: ["source", "destination"]),
            rawSpec("delete_file",
                "Move a file to recoverable quarantine. Permanent deletion is DISABLED by "
                + "data safeguards — the file is preserved and can be restored with "
                + "restore_file_snapshot. The path must be inside an authorized folder.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file to quarantine."],
                ], required: ["path"]),
            rawSpec("create_directory",
                "Create a directory and any intermediate directories. The path must be inside an authorized folder.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path of the directory to create."],
                ], required: ["path"]),
            rawSpec("list_file_snapshots",
                "List the rollback history for a file: every agent change (writes, appends, "
                + "moves, quarantined deletes) with snapshot IDs, kinds, and timestamps. "
                + "Use restore_file_snapshot with an ID to roll a change back.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file."],
                ], required: ["path"]),
            rawSpec("restore_file_snapshot",
                "Roll back a recorded change by its snapshot ID (from list_file_snapshots). "
                + "Restores preserved bytes over the file, moves a quarantined/moved file back "
                + "to its original path. The restore itself is snapshotted, so it is also reversible.",
                properties: [
                    "id": ["type": "integer", "description": "Snapshot ID from list_file_snapshots."],
                ], required: ["id"]),
        ]
    }

    struct ReadFileArgs: Decodable {
        let path: String?
        let offset: LenientInt?
        let limit: LenientInt?
    }
    // `append` is LenientBool: small models emit it as "false"/"true"
    // strings, which failed the whole decode and made write_file report
    // "requires 'path' and 'content'" even when both were present.
    struct WriteFileArgs: Decodable { let path: String?; let content: String?; let encoding: String?; let append: LenientBool? }
    private struct ListDirArgs: Codable { let path: String? }
    private struct OCRImageArgs: Codable { let path: String? }
    private struct CopyFileArgs: Codable { let source: String?; let destination: String? }
    private struct MoveFileArgs: Codable { let source: String?; let destination: String? }
    private struct DeleteFileArgs: Codable { let path: String? }
    private struct CreateDirectoryArgs: Codable { let path: String? }

    // MARK: - Path normalization

    /// Strip shell-style backslash escaping (e.g. `2\ AREAS` → `2 AREAS`) so that
    /// paths pasted from terminal output match real filesystem paths. This is
    /// applied before `URL(fileURLWithPath:)` so that `isAllowed` comparisons
    /// succeed regardless of how the path was originally entered.
    /// 
    /// Visibility: internal (used by both `MaestroTools+Files.swift` and `MaestroTools.swift`).
    static func unescapeShellPath(_ path: String) -> String {
        var result = ""
        let chars = Array(path)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\" else {
                result.append(chars[i])
                i += 1
                continue
            }
            // Gather the full backslash run. A run followed by a slash is an
            // over-escaped path separator from JSON-mimicking models (\/, \\/,
            // \\\/ — the read_file "no file at" and write_file "volume is
            // read only" failures were exactly this, not real I/O errors).
            var j = i
            while j < chars.count && chars[j] == "\\" { j += 1 }
            let runLength = j - i
            if j < chars.count, chars[j] == "/" {
                result.append("/")
                i = j + 1
            } else if j < chars.count {
                // True shell escape (e.g. `\ `): extra backslashes stay literal.
                if runLength > 1 { result.append(contentsOf: repeatElement("\\", count: runLength - 1)) }
                result.append(chars[j])
                i = j + 1
            } else {
                // Trailing backslash(es) — drop, matching the original behavior.
                break
            }
        }
        return result
    }

    /// Replace ALL invisible/alternative characters in a path so that
    /// model-generated paths match filesystem paths. Uses CharacterSet to catch
    /// every possible Unicode whitespace and control character, not just a
    /// hand-picked list. This is the single source of truth for path invisibles.
    /// 
    /// - Replaces any Unicode whitespace character with a regular space (U+0020)
    /// - Removes any Unicode control character (zero-width, BOM, soft hyphen, etc.)
    /// - Strips surrounding quotes that often get copied in from terminal/JSON
    /// - Applies NFC normalization so decomposed characters match precomposed ones
    static func normalizePathInvisibles(_ path: String) -> String {
        var result = ""
        let whitespaces = CharacterSet.whitespaces
        let controls = CharacterSet.controlCharacters
        for scalar in path.unicodeScalars {
            if whitespaces.contains(scalar) {
                // Replace any whitespace (including non-breaking space, em space, etc.)
                // with a regular ASCII space
                result.append(" ")
            } else if controls.contains(scalar) {
                // Skip control characters (zero-width space, BOM, soft hyphen, etc.)
                continue
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        // Strip surrounding quotes that get copied in from terminal/JSON output
        while result.hasPrefix("\"") || result.hasPrefix("'") {
            result.removeFirst()
        }
        while result.hasSuffix("\"") || result.hasSuffix("'") {
            result.removeLast()
        }
        // NFC normalization: macOS filesystem uses NFD, model output may be NFC
        return result.precomposedStringWithCanonicalMapping
    }

    /// Normalize a name for fuzzy comparison: lowercase and collapse curly/straight
    /// apostrophes, quotes, and dashes so "O'Hara" and "O'Hara" match.
    private static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
    }

    /// Simple Levenshtein distance for short names.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let (a, b) = (Array(a), Array(b))
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        var curr = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    /// Return the closest matching entries in `directory` to `targetName`,
    /// preferring exact normalized matches, then Levenshtein distance.
    private static func closestMatches(targetPath: String, directory: String, wantDirectory: Bool) -> [String] {
        let target = (targetPath as NSString).lastPathComponent
        let normalizedTarget = normalizedName(target)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let candidates = entries.filter { name in
            var isDir: ObjCBool = false
            let full = (directory as NSString).appendingPathComponent(name)
            _ = FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            return isDir.boolValue == wantDirectory
        }
        let exact = candidates.filter { normalizedName($0) == normalizedTarget }
        if !exact.isEmpty { return exact }
        return candidates
            .map { (name: $0, distance: levenshtein(normalizedTarget, normalizedName($0))) }
            .filter { $0.distance <= max(3, normalizedTarget.count / 3) }
            .sorted { $0.distance < $1.distance }
            .prefix(5)
            .map { $0.name }
    }

    /// If `resolved` doesn't exist, try to find the closest matching entry in its
    /// parent directory. This transparently fixes common model path errors like
    /// curly vs straight apostrophes (`O'Hara` vs `O'Hara`) without requiring the
    /// model to self-correct across a tool round-trip.
    static func fuzzyResolve(_ resolved: String, wantDirectory: Bool) -> String? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir),
           isDir.boolValue == wantDirectory {
            return resolved
        }
        let parent = (resolved as NSString).deletingLastPathComponent
        let matches = closestMatches(targetPath: resolved, directory: parent, wantDirectory: wantDirectory)
        guard let first = matches.first else { return nil }
        return (parent as NSString).appendingPathComponent(first)
    }

    /// Build a helpful "did you mean" suffix for missing path errors.
    static func didYouMean(path: String, wantDirectory: Bool) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let matches = closestMatches(targetPath: path, directory: parent, wantDirectory: wantDirectory)
        guard !matches.isEmpty else { return "" }
        let fullPaths = matches.map { (parent as NSString).appendingPathComponent($0) }
        return " Did you mean: \(fullPaths.joined(separator: ", "))?"
    }

    /// Enabled authorized roots from Settings → Context, standardized to absolute
    /// paths. A target path is permitted only if it equals one of these roots or
    /// is nested inside one. The agent's working directory is always an implicit
    /// root so the agent can create/edit files under it without manual setup.
    /// Project agents also inherit each other's working directories so a parent
    /// agent can verify files a sub-agent wrote under its own project path.
    ///
    /// When Full Disk Access is enabled, agents can read/write anywhere on the system.
    static func authorizedRoots() -> [String] {
        // Full Disk Access: bypass all restrictions, grant full filesystem access.
        if SwiftMaestroSettingsStore.loadFullDiskAccess() {
            return ["/"]
        }

        var roots = SwiftMaestroSettingsStore.loadAuthorizedFolders()
            .filter { $0.enabled }
            .map { path -> String in
                let expanded = unescapeShellPath((path.path as NSString).expandingTildeInPath)
                let cleaned = normalizePathInvisibles(expanded)
                return URL(fileURLWithPath: cleaned).standardizedFileURL.path
            }
            .filter { !$0.isEmpty }
        // Inherited roots from the parent agent during delegation.
        for r in inheritedRoots where !roots.contains(r) {
            roots.append(r)
        }
        if let wd = workingDirectory, !wd.isEmpty {
            let standardized = URL(fileURLWithPath: unescapeShellPath(wd)).standardizedFileURL.path
            if !roots.contains(standardized) {
                roots.append(standardized)
            }
        }
        // Working directories of agents that were delegated to during this run.
        // This lets a delegating agent verify or continue work a sub-agent
        // created under its own project-scoped path.
        for wd in MaestroTools.delegatedAgentWorkingDirectories where !roots.contains(wd) {
            roots.append(wd)
        }
        return roots
    }

    /// Resolve to an absolute, standardized path. Replaces invisible/alternative
    /// space characters and strips zero-width characters so model-generated paths
    /// match filesystem paths. Relative paths are resolved against the agent's
    /// current working directory when one is set.
    static func resolveAbsolute(_ path: String) -> String? {
        let expanded = unescapeShellPath((path as NSString).expandingTildeInPath)
        var cleaned = normalizePathInvisibles(expanded)
        if !cleaned.hasPrefix("/") {
            guard let workingDirectory = MaestroTools.workingDirectory, !workingDirectory.isEmpty else {
                return nil
            }
            cleaned = (workingDirectory as NSString).appendingPathComponent(cleaned)
        }
        return URL(fileURLWithPath: cleaned).standardizedFileURL.path
    }

    static func isAllowed(_ resolved: String, roots: [String]) -> Bool {
        // Full Disk Access installs "/" as the sole root to authorize every
        // path. The prefix test below would otherwise compare against "//" and
        // deny everything on FDA-enabled systems, so short-circuit here.
        if roots.contains("/") { return true }

        func normalize(_ p: String) -> String {
            var s = normalizePathInvisibles(p)
            s = s.trimmingCharacters(in: .whitespaces)
            while s.hasSuffix("/") && s.count > 1 { s = String(s.dropLast()) }
            return s
        }
        let normResolved = normalize(resolved)
        
        for root in roots {
            let normRoot = normalize(root)
            if normResolved == normRoot || normResolved.hasPrefix(normRoot + "/") {
                return true
            }
            // Case-insensitive fallback
            if normResolved.caseInsensitiveCompare(normRoot) == .orderedSame
                || normResolved.lowercased().hasPrefix(normRoot.lowercased() + "/") {
                return true
            }
            // Nuclear fallback: strip all non-alphanumeric except slashes
            func stripToCore(_ p: String) -> String {
                var result = ""
                for scalar in p.unicodeScalars {
                    if scalar == "/" || CharacterSet.alphanumerics.contains(scalar) {
                        result.unicodeScalars.append(scalar)
                    }
                }
                return result.lowercased()
            }
            let coreResolved = stripToCore(normResolved)
            let coreRoot = stripToCore(normRoot)
            if coreResolved == coreRoot || coreResolved.hasPrefix(coreRoot + "/") {
                return true
            }
        }
        return false
    }

    static func denied(_ path: String) -> String {
        let roots = authorizedRoots()
        let list = roots.isEmpty ? "(none configured)" : roots.joined(separator: ", ")
        return errorJSON(
            "access denied: '\(path)' is outside the authorized folders. "
            + "Authorized: \(list). Add it in Settings → Context.")
    }

    // MARK: - Polymorphic file reading

    private static func readBinaryContent(data: Data, path: String) -> String {
        let base64 = data.base64EncodedString()
        return jsonString([
            "type": "binary",
            "mime_type": FileContentExtractor.mimeType(for: path),
            "size_bytes": data.count,
            "base64": base64,
            "note": "This is a binary file. Use the base64 data if you need to process it, or ask for a specific extraction."
        ])
    }

    private static func applyLineLimit(
        _ text: String, offset: Int?, limit: Int?, totalSource: String, path: String, actualPath: String
    ) -> String {
        let allLines = text.components(separatedBy: .newlines)
        let totalLines = allLines.count
        let startLine = max(1, offset ?? 1)
        let maxLines = limit ?? (defaultReadLimit / 4)
        let endLine = min(totalLines, startLine + maxLines - 1)
        let slice = allLines[(startLine - 1)..<endLine]
        let prefix = "Lines \(startLine)-\(endLine) of \(totalLines):\n"
        // Only warn about truncation when the caller did not explicitly cap the
        // lines. If the model asked for exactly N lines, the suffix "... (X more
        // lines)" makes small models think the read was truncated and they loop
        // trying to re-read the same file.
        let hasExplicitLimit = limit != nil
        let truncated = (endLine < totalLines && !hasExplicitLimit)
            ? prefix + slice.joined(separator: "\n") + "\n... (\(totalLines - endLine) more lines)"
            : prefix + slice.joined(separator: "\n")
        return truncated + (actualPath == path ? "" : "\n[resolved path: \(actualPath)]")
    }

    static func readFile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadFileArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            NSLog("[read_file] missing path; args=%@", call.function.arguments)
            return errorJSON("read_file requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            NSLog("[read_file] could not resolve path '%@' against working directory '%@'", raw, MaestroTools.workingDirectory ?? "(none)")
            return errorJSON("read_file requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else {
            NSLog("[read_file] access denied for '%@' (resolved: '%@'); roots=%@", raw, resolved, authorizedRoots())
            return denied(raw)
        }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actualPath, isDirectory: &isDir), !isDir.boolValue else {
            NSLog("[read_file] no file at '%@' (resolved: '%@')", raw, actualPath)
            return errorJSON("no file at '\(resolved)'.\(didYouMean(path: resolved, wantDirectory: false))")
        }
        guard let data = FileManager.default.contents(atPath: actualPath) else {
            NSLog("[read_file] could not read contents of '%@'", actualPath)
            return errorJSON("could not read '\(actualPath)'")
        }
        NSLog("[read_file] success: raw='%@' resolved='%@' size=%d bytes", raw, actualPath, data.count)
        guard data.count <= maxReadBytes else {
            return errorJSON("file too large (\(data.count) bytes; limit \(maxReadBytes)).")
        }

        let category = FileContentExtractor.category(for: actualPath)

        switch category {
        case .text:
            if let text = FileContentExtractor.extractText(from: actualPath) {
                let result = applyLineLimit(text, offset: args.offset?.value, limit: args.limit?.value,
                                            totalSource: text, path: resolved, actualPath: actualPath)
                NSLog("[read_file] returning text result: %@", String(result.prefix(200)))
                return result
            }
            return readBinaryContent(data: data, path: actualPath)

        case .pdf, .document:
            if let text = FileContentExtractor.extractText(from: actualPath), !text.isEmpty {
                let result = applyLineLimit(text, offset: args.offset?.value, limit: args.limit?.value,
                                            totalSource: text, path: resolved, actualPath: actualPath)
                NSLog("[read_file] returning document result: %@", String(result.prefix(200)))
                return result
            }
            // Fall through to binary representation if document extraction fails.
            return readBinaryContent(data: data, path: actualPath)

        case .image, .binary:
            return readBinaryContent(data: data, path: actualPath)
        }
    }

    static func writeFile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: WriteFileArgs.self) else {
            return errorJSON(
                "write_file could not decode its arguments (\(argDiagnostics(call))). "
                    + "Pass 'path' and 'content' as strings; 'append' accepts a boolean.")
        }
        guard let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let content = args.content else {
            return errorJSON("write_file requires 'path' and 'content' (\(argDiagnostics(call)))")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("write_file requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let url = URL(fileURLWithPath: resolved)
        let encoding = args.encoding?.lowercased() ?? "utf8"

        // Data safeguard: preserve existing bytes before mutating. Fail
        // closed — an unsnapshotable change is an unrollbackable change.
        if FileManager.default.fileExists(atPath: resolved) {
            do {
                try ChangeGuard.shared.snapshotForMutation(
                    path: resolved,
                    kind: (args.append?.value ?? false) ? .append : .overwrite,
                    tool: "write_file")
            } catch {
                return errorJSON(
                    "write blocked: could not create a rollback snapshot for '\(resolved)' "
                    + "(\(error.localizedDescription)). Data safeguards require every change to be reversible.")
            }
        }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let append = args.append?.value ?? false
            let bytesWritten: Int
            if append && FileManager.default.fileExists(atPath: resolved) {
                if encoding == "base64" {
                    guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
                        return errorJSON("write_file could not decode content as base64")
                    }
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                    bytesWritten = data.count
                } else {
                    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let newContent = existing + content
                    try newContent.write(to: url, atomically: true, encoding: .utf8)
                    bytesWritten = content.utf8.count
                }
            } else if encoding == "base64" {
                guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
                    return errorJSON("write_file could not decode content as base64")
                }
                try data.write(to: url, options: .atomic)
                bytesWritten = data.count
            } else {
                // Default and explicit utf8 path.
                try content.write(to: url, atomically: true, encoding: .utf8)
                bytesWritten = content.utf8.count
            }
            let status = append ? "appended" : "written"
            return jsonString(["status": status, "path": resolved, "bytes": "\(bytesWritten)"])
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
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let actualPath = fuzzyResolve(resolved, wantDirectory: true) ?? resolved
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actualPath, isDirectory: &isDir), isDir.boolValue else {
            return errorJSON("no directory at '\(resolved)'.\(didYouMean(path: resolved, wantDirectory: true))")
        }
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: actualPath).sorted()
            guard !items.isEmpty else { return "(empty directory) \(resolved)" }
            let lines = items.map { name -> String in
                var sub: ObjCBool = false
                _ = FileManager.default.fileExists(
                    atPath: (actualPath as NSString).appendingPathComponent(name), isDirectory: &sub)
                return sub.boolValue ? "\(name)/" : name
            }
            let header = "Contents of \(actualPath) (\(items.count)):"
            let note = actualPath == resolved ? "" : " [resolved from '\(resolved)']"
            return header + note + "\n" + lines.joined(separator: "\n")
        } catch {
            return errorJSON("failed to list '\(resolved)': \(error.localizedDescription)")
        }
    }

    static func ocrImage(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: OCRImageArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("ocr_image requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("ocr_image requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        guard FileManager.default.fileExists(atPath: actualPath) else {
            return errorJSON("no file at '\(resolved)'.\(didYouMean(path: resolved, wantDirectory: false))")
        }
        let ext = (actualPath as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "bmp", "webp"]
        guard imageExts.contains(ext) else {
            return errorJSON(
                "ocr_image only supports image files (\(imageExts.sorted().joined(separator: ", "))). "
                + "Got '\(ext)'. Use read_file for text/PDF content.")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: actualPath)) else {
            return errorJSON("failed to read image at '\(actualPath)'")
        }
        // Return a VLM payload: the agent executor detects __vlm_image__ and
        // injects this as a multimodal user message to the vision model.
        let json: [String: Any] = [
            "__vlm_image__": true,
            "path": actualPath,
            "data": data.base64EncodedString(),
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: jsonData, encoding: .utf8) else {
            return errorJSON("failed to encode VLM payload")
        }
        return str
    }

    // MARK: - File operations

    static func copyFile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: CopyFileArgs.self),
              let rawSource = args.source?.trimmingCharacters(in: .whitespaces), !rawSource.isEmpty,
              let rawDest = args.destination?.trimmingCharacters(in: .whitespaces), !rawDest.isEmpty else {
            return errorJSON("copy_file requires 'source' and 'destination'")
        }
        guard let source = resolveAbsolute(rawSource) else {
            return errorJSON("copy_file requires an absolute source path (got '\(rawSource)')")
        }
        guard let destination = resolveAbsolute(rawDest) else {
            return errorJSON("copy_file requires an absolute destination path (got '\(rawDest)')")
        }
        let roots = authorizedRoots()
        guard isAllowed(source, roots: roots) else { return denied(rawSource) }
        guard isAllowed(destination, roots: roots) else { return denied(rawDest) }
        let actualSource = fuzzyResolve(source, wantDirectory: false) ?? source
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actualSource, isDirectory: &isDir), !isDir.boolValue else {
            return errorJSON("no file at '\(source)'\(didYouMean(path: source, wantDirectory: false))")
        }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination) {
                // Data safeguard: preserve the file we're about to overwrite.
                do {
                    try ChangeGuard.shared.snapshotForMutation(
                        path: destination, kind: .copyOverwrite,
                        relatedPath: actualSource, tool: "copy_file")
                } catch {
                    return errorJSON(
                        "copy blocked: could not snapshot existing destination '\(destination)' "
                        + "(\(error.localizedDescription)). Data safeguards require every change to be reversible.")
                }
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.copyItem(atPath: actualSource, toPath: destination)
            return jsonString(["status": "copied", "source": actualSource, "destination": destination])
        } catch {
            return errorJSON("failed to copy '\(actualSource)' to '\(destination)': \(error.localizedDescription)")
        }
    }

    static func moveFile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: MoveFileArgs.self),
              let rawSource = args.source?.trimmingCharacters(in: .whitespaces), !rawSource.isEmpty,
              let rawDest = args.destination?.trimmingCharacters(in: .whitespaces), !rawDest.isEmpty else {
            return errorJSON("move_file requires 'source' and 'destination'")
        }
        guard let source = resolveAbsolute(rawSource) else {
            return errorJSON("move_file requires an absolute source path (got '\(rawSource)')")
        }
        guard let destination = resolveAbsolute(rawDest) else {
            return errorJSON("move_file requires an absolute destination path (got '\(rawDest)')")
        }
        let roots = authorizedRoots()
        guard isAllowed(source, roots: roots) else { return denied(rawSource) }
        guard isAllowed(destination, roots: roots) else { return denied(rawDest) }
        let actualSource = fuzzyResolve(source, wantDirectory: false) ?? source
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actualSource, isDirectory: &isDir), !isDir.boolValue else {
            return errorJSON("no file at '\(source)'\(didYouMean(path: source, wantDirectory: false))")
        }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            // Data safeguards: preserve an existing destination, and record
            // the move itself (rollback = move back via restore_file_snapshot).
            if FileManager.default.fileExists(atPath: destination) {
                do {
                    try ChangeGuard.shared.snapshotForMutation(
                        path: destination, kind: .copyOverwrite,
                        relatedPath: actualSource, tool: "move_file")
                } catch {
                    return errorJSON(
                        "move blocked: could not snapshot existing destination '\(destination)' "
                        + "(\(error.localizedDescription)). Data safeguards require every change to be reversible.")
                }
                try FileManager.default.removeItem(atPath: destination)
            }
            do {
                try ChangeGuard.shared.snapshotForMutation(
                    path: actualSource, kind: .move,
                    relatedPath: destination, tool: "move_file")
            } catch {
                return errorJSON(
                    "move blocked: could not record the move for '\(actualSource)' "
                    + "(\(error.localizedDescription)). Data safeguards require every change to be reversible.")
            }
            try FileManager.default.moveItem(atPath: actualSource, toPath: destination)
            return jsonString(["status": "moved", "source": actualSource, "destination": destination])
        } catch {
            return errorJSON("failed to move '\(actualSource)' to '\(destination)': \(error.localizedDescription)")
        }
    }

    static func deleteFile(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DeleteFileArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("delete_file requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("delete_file requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actualPath, isDirectory: &isDir), !isDir.boolValue else {
            return errorJSON("no file at '\(resolved)'\(didYouMean(path: resolved, wantDirectory: false))")
        }
        // Data safeguards: permanent deletion is disabled. The file is moved
        // to a recoverable quarantine store and can be rolled back with
        // restore_file_snapshot (or by the user from the ChangeGuard store).
        do {
            let quarantinePath = try ChangeGuard.shared.quarantineDelete(
                path: actualPath, tool: "delete_file")
            return jsonString([
                "status": "quarantined",
                "path": actualPath,
                "quarantine_path": quarantinePath,
                "note": "File moved to recoverable quarantine. Permanent deletion is disabled "
                    + "by data safeguards. Roll back with restore_file_snapshot.",
            ])
        } catch {
            return errorJSON("failed to quarantine '\(actualPath)': \(error.localizedDescription)")
        }
    }

    static func listFileSnapshots(_ call: ToolCall) async -> String {
        struct Args: Decodable { let path: String? }
        guard let args = decodeArgs(call, as: Args.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("list_file_snapshots requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("list_file_snapshots requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        let changes = ChangeGuard.shared.listChanges(forPath: resolved)
        guard !changes.isEmpty else {
            return jsonString(["path": resolved, "count": "0",
                               "message": "No recorded changes for this file."])
        }
        let rows: [[String: String]] = changes.map { change in
            var row: [String: String] = [
                "id": "\(change.id ?? -1)",
                "kind": change.kind.rawValue,
                "when": ISO8601DateFormatter().string(from: change.createdAt),
                "tool": change.tool,
            ]
            if let size = change.sizeBytes { row["bytes"] = "\(size)" }
            if let related = change.relatedPath { row["related_path"] = related }
            return row
        }
        let payload: [String: Any] = ["path": resolved, "count": rows.count, "changes": rows]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return errorJSON("failed to encode snapshot list")
        }
        return str
    }

    static func restoreFileSnapshot(_ call: ToolCall) async -> String {
        struct Args: Decodable { let id: LenientInt? }
        guard let args = decodeArgs(call, as: Args.self),
              let id = args.id?.value else {
            return errorJSON("restore_file_snapshot requires an integer 'id' (from list_file_snapshots)")
        }
        do {
            let message = try ChangeGuard.shared.restore(changeId: Int64(id))
            return jsonString(["status": "restored", "detail": message])
        } catch {
            return errorJSON("restore failed: \(error.localizedDescription)")
        }
    }

    static func createDirectory(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: CreateDirectoryArgs.self),
              let raw = args.path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return errorJSON("create_directory requires 'path'")
        }
        guard let resolved = resolveAbsolute(raw) else {
            return errorJSON("create_directory requires an absolute path (got '\(raw)')")
        }
        guard isAllowed(resolved, roots: authorizedRoots()) else { return denied(raw) }
        do {
            try FileManager.default.createDirectory(
                atPath: resolved, withIntermediateDirectories: true, attributes: nil)
            return jsonString(["status": "created", "path": resolved])
        } catch {
            return errorJSON("failed to create directory '\(resolved)': \(error.localizedDescription)")
        }
    }
}
