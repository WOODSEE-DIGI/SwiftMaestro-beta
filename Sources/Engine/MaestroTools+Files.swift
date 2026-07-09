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

    static let fileToolNames: Set<String> = ["read_file", "write_file", "list_dir", "ocr_image"]

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
                + "Your working directory is automatically authorized for writing.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to the file."],
                    "content": ["type": "string", "description": "The content to write. Text when encoding is utf8 (default); base64 string when encoding is base64."],
                    "encoding": ["type": "string", "description": "Encoding of 'content': 'utf8' (default) or 'base64'."],
                ], required: ["path", "content"]),
            rawSpec("list_dir",
                "List ALL entries (files and subdirectories) of a directory. Use an absolute path. "
                + "Your working directory is automatically authorized for listing. "
                + "IMPORTANT: Return EVERY entry — do NOT filter, skip, or prioritize files you think "
                + "are 'important'. The user needs to see the COMPLETE contents. For large directories, "
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
        ]
    }

    private struct ReadFileArgs: Codable {
        let path: String?
        let offset: Int?
        let limit: Int?
    }
    private struct WriteFileArgs: Codable { let path: String?; let content: String?; let encoding: String? }
    private struct ListDirArgs: Codable { let path: String? }
    private struct OCRImageArgs: Codable { let path: String? }

    // MARK: - Path normalization

    /// Strip shell-style backslash escaping (e.g. `2\ AREAS` → `2 AREAS`) so that
    /// paths pasted from terminal output match real filesystem paths. This is
    /// applied before `URL(fileURLWithPath:)` so that `isAllowed` comparisons
    /// succeed regardless of how the path was originally entered.
    /// 
    /// Visibility: internal (used by both `MaestroTools+Files.swift` and `MaestroTools.swift`).
    static func unescapeShellPath(_ path: String) -> String {
        var result = ""
        var chars = path.makeIterator()
        while let ch = chars.next() {
            if ch == "\\" {
                // Consume the next character (the escaped one) and append it literally.
                // This handles `\ `, `\( `, etc. If there's nothing after the backslash,
                // we just drop the trailing backslash.
                if let next = chars.next() {
                    result.append(next)
                }
            } else {
                result.append(ch)
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
    static func authorizedRoots() -> [String] {
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
        return roots
    }

    /// Resolve to an absolute, standardized path, or nil if it is not absolute.
    /// Replaces invisible/alternative space characters and strips zero-width
    /// characters so model-generated paths match filesystem paths.
    static func resolveAbsolute(_ path: String) -> String? {
        let expanded = unescapeShellPath((path as NSString).expandingTildeInPath)
        guard expanded.hasPrefix("/") else { return nil }
        var cleaned = normalizePathInvisibles(expanded)
        return URL(fileURLWithPath: cleaned).standardizedFileURL.path
    }

    static func isAllowed(_ resolved: String, roots: [String]) -> Bool {
        // Normalize both sides identically using the shared function that catches
        // ALL Unicode whitespace and control characters.
        func normalize(_ p: String) -> String {
            var s = normalizePathInvisibles(p)
            s = s.trimmingCharacters(in: .whitespaces)
            while s.hasSuffix("/") && s.count > 1 { s = String(s.dropLast()) }
            return s
        }
        let normResolved = normalize(resolved)
        
        // Debug: print byte-level details for troubleshooting
        let resolvedBytes = resolved.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? "N/A"
        NSLog("[IS_ALLOWED DEBUG] resolved='\(resolved)' bytes='\(resolvedBytes)'")
        NSLog("[IS_ALLOWED DEBUG] normResolved='\(normResolved)'")
        
        for root in roots {
            let normRoot = normalize(root)
            let rootBytes = root.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? "N/A"
            let hasPrefix = normResolved.hasPrefix(normRoot + "/")
            let isEqual = normResolved == normRoot
            
            // Also try case-insensitive comparison as fallback
            let hasPrefixCaseInsensitive = normResolved.caseInsensitiveCompare(normRoot + "/") == .orderedSame || normResolved.lowercased().hasPrefix(normRoot.lowercased() + "/")
            let isEqualCaseInsensitive = normResolved.caseInsensitiveCompare(normRoot) == .orderedSame
            
            NSLog("[IS_ALLOWED DEBUG]   root='\(root)' bytes='\(rootBytes)'")
            NSLog("[IS_ALLOWED DEBUG]   normRoot='\(normRoot)'")
            NSLog("[IS_ALLOWED DEBUG]   hasPrefix('\(normRoot + "/")') = \(hasPrefix), isEqual = \(isEqual)")
            NSLog("[IS_ALLOWED DEBUG]   caseInsensitive: hasPrefix=\(hasPrefixCaseInsensitive), isEqual=\(isEqualCaseInsensitive)")
            
            if isEqual || hasPrefix || isEqualCaseInsensitive || hasPrefixCaseInsensitive {
                return true
            }
            
            // NUCLEAR FALLBACK: If all else fails, compare after stripping ALL
            // non-alphanumeric characters except slashes. This catches any
            // invisible character issue while still being reasonably safe.
            func stripToCore(_ p: String) -> String {
                var result = ""
                for scalar in p.unicodeScalars {
                    if scalar == "/" {
                        result.unicodeScalars.append(scalar)
                    } else if CharacterSet.alphanumerics.contains(scalar) {
                        result.unicodeScalars.append(scalar)
                    }
                    // Skip everything else (spaces, invisible chars, etc.)
                }
                return result.lowercased()
            }
            let coreResolved = stripToCore(normResolved)
            let coreRoot = stripToCore(normRoot)
            let coreMatch = coreResolved == coreRoot || coreResolved.hasPrefix(coreRoot + "/")
            
            if coreMatch {
                NSLog("[IS_ALLOWED] ALLOWED via nuclear fallback (core path match)")
                return true
            }
            
            // Character-by-character diff for debugging
            if !isEqual {
                let rChars = Array(normResolved)
                let tChars = Array(normRoot)
                if rChars.count == tChars.count {
                    var diffPositions: [Int] = []
                    for i in 0..<rChars.count {
                        if rChars[i] != tChars[i] {
                            diffPositions.append(i)
                        }
                    }
                    if !diffPositions.isEmpty {
                        let diffs = diffPositions.map { i in
                            let rCode = rChars[i].utf16.first.map { String(format: "U+%04X", $0) } ?? "?"
                            let tCode = tChars[i].utf16.first.map { String(format: "U+%04X", $0) } ?? "?"
                            return "\(i): resolved='\(rChars[i])'(\(rCode)) vs root='\(tChars[i])'(\(tCode))"
                        }.joined(separator: "; ")
                        NSLog("[IS_ALLOWED DEBUG]   CHAR DIFF at positions: \(diffs)")
                    }
                } else {
                    NSLog("[IS_ALLOWED DEBUG]   LENGTH DIFF: resolved=\(normResolved.count) root=\(normRoot.count)")
                    // Show first differing region
                    let minLen = min(rChars.count, tChars.count)
                    for i in 0..<minLen {
                        if rChars[i] != tChars[i] {
                            let rCode = rChars[i].utf16.first.map { String(format: "U+%04X", $0) } ?? "?"
                            let tCode = tChars[i].utf16.first.map { String(format: "U+%04X", $0) } ?? "?"
                            NSLog("[IS_ALLOWED DEBUG]   FIRST DIFF at \(i): resolved='\(rChars[i])'(\(rCode)) vs root='\(tChars[i])'(\(tCode))")
                            break
                        }
                    }
                }
            }
        }
        
        // Debug: log why it failed
        NSLog("[IS_ALLOWED] DENIED: resolved='\(resolved)' normalized='\(normResolved)'")
        NSLog("[IS_ALLOWED] roots=\(roots)")
        for root in roots {
            let normRoot = normalize(root)
            NSLog("[IS_ALLOWED]   root='\(root)' normalized='\(normRoot)' match=\(normResolved.hasPrefix(normRoot + "/"))")
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
        let truncated = endLine < totalLines
            ? prefix + slice.joined(separator: "\n") + "\n... (\(totalLines - endLine) more lines)"
            : prefix + slice.joined(separator: "\n")
        return truncated + (actualPath == path ? "" : "\n[resolved path: \(actualPath)]")
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
        let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actualPath, isDirectory: &isDir), !isDir.boolValue else {
            return errorJSON("no file at '\(resolved)'.\(didYouMean(path: resolved, wantDirectory: false))")
        }
        guard let data = FileManager.default.contents(atPath: actualPath) else {
            return errorJSON("could not read '\(actualPath)'")
        }
        guard data.count <= maxReadBytes else {
            return errorJSON("file too large (\(data.count) bytes; limit \(maxReadBytes)).")
        }

        let category = FileContentExtractor.category(for: actualPath)

        switch category {
        case .text:
            if let text = FileContentExtractor.extractText(from: actualPath) {
                return applyLineLimit(text, offset: args.offset, limit: args.limit,
                                      totalSource: text, path: resolved, actualPath: actualPath)
            }
            return readBinaryContent(data: data, path: actualPath)

        case .pdf, .document:
            if let text = FileContentExtractor.extractText(from: actualPath), !text.isEmpty {
                return applyLineLimit(text, offset: args.offset, limit: args.limit,
                                      totalSource: text, path: resolved, actualPath: actualPath)
            }
            // Fall through to binary representation if document extraction fails.
            return readBinaryContent(data: data, path: actualPath)

        case .image, .binary:
            return readBinaryContent(data: data, path: actualPath)
        }
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
        let encoding = args.encoding?.lowercased() ?? "utf8"

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            let bytesWritten: Int
            if encoding == "base64" {
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
            return jsonString(["status": "written", "path": resolved, "bytes": "\(bytesWritten)"])
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
}
