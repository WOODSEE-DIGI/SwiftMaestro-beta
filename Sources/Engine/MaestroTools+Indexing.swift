import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Directory indexing tools
//
// Tools for recursively scanning directories, extracting Spotlight metadata,
// and saving structured indexes to shared memory. This enables agents to
// quickly understand large directories without reading every file.

extension MaestroTools {

    static func registerIndexTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "index_directory", spec: indexToolSpecs[0],
                category: ToolCategory.index.rawValue,
                handler: { call in await indexDirectory(call) }),
            ToolDefinition(
                name: "save_index", spec: indexToolSpecs[1],
                category: ToolCategory.index.rawValue,
                handler: { call in await saveIndex(call) }),
            ToolDefinition(
                name: "spotlight_search", spec: indexToolSpecs[2],
                category: ToolCategory.index.rawValue,
                handler: { call in await spotlightSearch(call) }),
            ToolDefinition(
                name: "index_document", spec: indexToolSpecs[3],
                category: ToolCategory.index.rawValue,
                handler: { call in await indexDocument(call) }),
            ToolDefinition(
                name: "search_chunks", spec: indexToolSpecs[4],
                category: ToolCategory.index.rawValue,
                handler: { call in await searchChunks(call) }),
            ToolDefinition(
                name: "read_chunk", spec: indexToolSpecs[5],
                category: ToolCategory.index.rawValue,
                handler: { call in await readChunk(call) }),
        ])
    }



    static var indexToolSpecs: [ToolSpec] {
        [
            rawSpec("index_directory",
                "Recursively scan directories and save a structured index of ALL files "
                + "and subdirectories using macOS Spotlight metadata (no file reading). "
                + "The index is automatically saved to shared memory — you do NOT need to "
                + "call save_index afterwards. Returns a summary with the saved URI, counts, "
                + "and total size. Use 'depth' to limit recursion (0 = top-level only). "
                + "Use 'includeMetadata' for Spotlight details (default true). "
                + "FORMAT: Always use 'paths' as a JSON array of strings. "
                + "Example: {\"paths\": [\"/dir/a\", \"/dir/b\", \"/dir/c\"]}. "
                + "NEVER call this tool multiple times — put ALL directories in one 'paths' array.",
                properties: [
                    "paths": [
                        "type": "array",
                        "items": ["type": "string"] as [String: any Sendable],
                        "description": "JSON array of absolute directory paths. ALWAYS use this. Example: [\"/path/to/dir1\", \"/path/to/dir2\"]"
                    ] as [String: any Sendable],
                    "depth": ["type": "integer", "description": "Max recursion depth (0 = top-level only, default = unlimited)."],
                    "includeMetadata": ["type": "boolean", "description": "Include Spotlight metadata (default true). Set false for a fast name-only scan."],
                    "name": ["type": "string", "description": "Optional name for the saved index. If omitted, derived from the directory path(s)."],
                    "project": ["type": "string", "description": "Optional project scope for the saved index."],
                ], required: ["paths"]),
            rawSpec("save_index",
                "Save a directory index to shared memory so it persists across sessions "
                + "and is visible to all agents. Use after index_directory to preserve "
                + "the results. The index is stored under the project's knowledge base.",
                properties: [
                    "index": ["type": "string", "description": "The index content (JSON or markdown) to save."],
                    "name": ["type": "string", "description": "A name for this index (e.g. 'mystory-backend-index')."],
                    "project": ["type": "string", "description": "Optional project to scope the index to."],
                ], required: ["index", "name"]),
            rawSpec("spotlight_search",
                "Search macOS Spotlight for files matching a query. Returns file paths and rich "
                + "metadata (size, dates, dimensions, Finder tags, color labels, GPS, authors, etc.) "
                + "WITHOUT reading file contents. Works across all mounted volumes. "
                + "Two query modes: (1) Simple text: searches file names. (2) Predicate format: "
                + "use NSPredicate syntax like 'kMDItemContentType == \"public.jpeg\"' or "
                + "'kMDItemFSSize > 1000000'. Common keys: kMDItemFSName, kMDItemContentType, "
                + "kMDItemFSSize, kMDItemContentModificationDate, kMDItemKind, kMDItemCity, "
                + "kMDItemAuthors, kMDItemTitle. Use 'scope' to limit to a directory.",
                properties: [
                    "query": ["type": "string", "description": "Search query. Simple text (e.g. 'receipt') or NSPredicate format (e.g. 'kMDItemContentType == \"public.jpeg\" AND kMDItemFSSize > 1000000')."],
                    "scope": ["type": "string", "description": "Optional directory to limit search scope. Default: all indexed volumes."],
                    "detailed": ["type": "boolean", "description": "Return full metadata for each result (default false — returns paths only)."],
                    "limit": ["type": "integer", "description": "Max results to return (default 50)."],
                ], required: ["query"]),
            rawSpec("index_document",
                "Read one or more files, split them into searchable chunks, and save the chunks "
                + "to a named index. Use this for large documents (.docx, .pdf, .txt, .md, .rtf) "
                + "that won't fit in the model's context window. The index stores EXACT text chunks "
                + "— no summarization, no paraphrasing. After indexing, use search_chunks to find "
                + "relevant chunks and read_chunk to retrieve the exact original text.",
                properties: [
                    "paths": [
                        "type": "array",
                        "items": ["type": "string"] as [String: any Sendable],
                        "description": "JSON array of absolute file paths to index."
                    ] as [String: any Sendable],
                    "index_name": ["type": "string", "description": "Name for this chunk index. Use the same name later with search_chunks/read_chunk."],
                    "chunk_words": ["type": "integer", "description": "Approximate words per chunk (default 500)."],
                    "overlap_words": ["type": "integer", "description": "Words of overlap between adjacent chunks (default 100)."],
                    "project": ["type": "string", "description": "Optional project scope for the index."],
                ], required: ["paths", "index_name"]),
            rawSpec("search_chunks",
                "Search a chunk index created by index_document. Uses keyword + fuzzy matching "
                + "so loose queries still find relevant chunks. Returns chunk IDs, source files, "
                + "relevance scores, and short previews. ALWAYS follow up with read_chunk to get "
                + "the exact full text — never quote from the preview alone.",
                properties: [
                    "index_name": ["type": "string", "description": "Name of the chunk index to search."],
                    "query": ["type": "string", "description": "Search query. Use multiple keywords for better recall."],
                    "top_k": ["type": "integer", "description": "Max chunks to return (default 10)."],
                    "project": ["type": "string", "description": "Optional project scope if the index was created with one."],
                ], required: ["index_name", "query"]),
            rawSpec("read_chunk",
                "Retrieve the EXACT full text of a single chunk from a chunk index. Use this "
                + "after search_chunks to read the real content. The chunk text is returned verbatim "
                + "from the original file — no summarization.",
                properties: [
                    "index_name": ["type": "string", "description": "Name of the chunk index."],
                    "chunk_id": ["type": "string", "description": "Chunk ID returned by search_chunks."],
                    "project": ["type": "string", "description": "Optional project scope if the index was created with one."],
                ], required: ["index_name", "chunk_id"]),
        ]
    }

    private struct IndexDirectoryArgs: Codable {
        var paths: [String]?
        let depth: Int?
        let includeMetadata: Bool?
        let name: String?
        let project: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Try to decode paths as array first
            paths = try? container.decode([String].self, forKey: .paths)
            // If paths is nil, try to decode a single path string and wrap it
            if paths == nil || paths?.isEmpty == true {
                if let singlePath = try? container.decode(String.self, forKey: .paths) {
                    let trimmed = singlePath.trimmingCharacters(in: .whitespaces)
                    // Handle the common LLM mistake: stringified JSON array
                    // e.g. paths: "[\"/dir/a\", \"/dir/b\"]" instead of paths: ["/dir/a", "/dir/b"]
                    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                        if let data = trimmed.data(using: .utf8),
                           let parsed = try? JSONDecoder().decode([String].self, from: data) {
                            paths = parsed
                        } else {
                            // Not valid JSON array — treat as single path (strip brackets)
                            let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                            if !inner.isEmpty {
                                paths = [inner]
                            }
                        }
                    } else {
                        paths = [trimmed]
                    }
                }
            }
            depth = try? container.decode(Int.self, forKey: .depth)
            includeMetadata = try? container.decode(Bool.self, forKey: .includeMetadata)
            name = try? container.decode(String.self, forKey: .name)
            project = try? container.decode(String.self, forKey: .project)
        }

        enum CodingKeys: String, CodingKey {
            case paths, depth, includeMetadata, name, project
        }

        /// Returns the resolved list of directory paths to index.
        var resolvedPaths: [String] {
            return paths ?? []
        }
    }

    private struct SaveIndexArgs: Codable {
        let index: String?
        let name: String?
        let project: String?
    }

    private struct IndexDocumentArgs: Codable {
        let paths: [String]?
        let index_name: String?
        let chunk_words: Int?
        let overlap_words: Int?
        let project: String?
    }

    private struct SearchChunksArgs: Codable {
        let index_name: String?
        let query: String?
        let top_k: Int?
        let project: String?
    }

    private struct ReadChunkArgs: Codable {
        let index_name: String?
        let chunk_id: String?
        let project: String?
    }

    /// Recursively index one or more directories, returning a structured summary.
    /// Uses Spotlight metadata for rich info without reading file contents.
    static func indexDirectory(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: IndexDirectoryArgs.self) else {
            return errorJSON("could not parse arguments for index_directory")
        }
        let rawPaths = args.resolvedPaths
        guard !rawPaths.isEmpty else {
            return errorJSON("index_directory requires 'paths' as a JSON array of directory paths. Example: {\"paths\": [\"/dir/a\", \"/dir/b\"]}")
        }

        // Resolve and validate each path
        let roots = authorizedRoots()
        var resolvedPaths: [(raw: String, resolved: String)] = []
        for raw in rawPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let resolved = resolveAbsolute(trimmed) else {
                return errorJSON("index_directory requires an absolute path (got '\(trimmed)')")
            }
            guard isAllowed(resolved, roots: roots) else {
                NSLog("[INDEX_DIR] DENIED: resolved='\(resolved)' roots=\(roots)")
                return denied(trimmed)
            }
            let actualPath = fuzzyResolve(resolved, wantDirectory: true) ?? resolved
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: actualPath, isDirectory: &isDir), isDir.boolValue else {
                return errorJSON("no directory at '\(resolved)'.\(didYouMean(path: resolved, wantDirectory: true))")
            }
            resolvedPaths.append((trimmed, actualPath))
        }
        guard !resolvedPaths.isEmpty else {
            return errorJSON("no valid directories found in the provided paths")
        }

        let maxDepth = args.depth ?? -1  // -1 = unlimited
        let includeMetadata = args.includeMetadata ?? true

        // Index each directory and collect results
        var directoryResults: [[String: Any]] = []
        for (_, actualPath) in resolvedPaths {
            let result = indexSingleDirectory(
                path: actualPath, maxDepth: maxDepth, includeMetadata: includeMetadata)
            directoryResults.append(result)
        }

        // Build the full index payload and auto-save it so the agent doesn't have
        // to call save_index separately (which often fails when the index is huge
        // because it inflates the chat context beyond the token budget).
        let indexPayload: [String: Any]
        if directoryResults.count == 1 {
            indexPayload = directoryResults[0]
        } else {
            var totalFiles = 0
            var totalDirs = 0
            var totalSizeBytes: Int64 = 0
            for r in directoryResults {
                totalFiles += (r["total_files"] as? Int) ?? 0
                totalDirs += (r["total_directories"] as? Int) ?? 0
                if let sizeStr = r["total_size"] as? String,
                   let bytes = parseBytes(sizeStr) {
                    totalSizeBytes += bytes
                }
            }
            indexPayload = [
                "directories_indexed": resolvedPaths.count,
                "total_files": totalFiles,
                "total_directories": totalDirs,
                "total_size": formatBytes(totalSizeBytes),
                "results": directoryResults,
            ]
        }

        guard let indexData = try? JSONSerialization.data(withJSONObject: indexPayload, options: .prettyPrinted),
              let indexString = String(data: indexData, encoding: .utf8) else {
            return errorJSON("index_directory failed to serialize index")
        }

        // Derive a name if the model didn't provide one
        let indexName: String
        if let providedName = args.name?.trimmingCharacters(in: .whitespaces), !providedName.isEmpty {
            indexName = providedName
        } else if directoryResults.count == 1,
                  let rootPath = directoryResults.first?["directory"] as? String {
            indexName = (rootPath as NSString).lastPathComponent
        } else {
            let components = resolvedPaths.map { ($0.resolved as NSString).lastPathComponent }
            indexName = "multi-index-\(components.joined(separator: "-"))"
        }

        let memoryStore = SimpleMemoryStore()
        let project = args.project?.trimmingCharacters(in: .whitespaces)
        let sanitizedName = indexName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        let uri: MaestroURI
        if let project, !project.isEmpty {
            uri = MaestroURI(kind: .knowledge, path: ["indexes", project, sanitizedName])
        } else {
            uri = MaestroURI(kind: .knowledge, path: ["indexes", sanitizedName])
        }

        do {
            try memoryStore.save(indexString, at: uri)
        } catch {
            return errorJSON("index_directory succeeded but failed to save index: \(error.localizedDescription)")
        }

        // Return only a compact summary to the model — the full index is already saved.
        let summary: [String: Any] = [
            "status": "indexed_and_saved",
            "saved_uri": "maestro://knowledge/\(uri.path.joined(separator: "/"))",
            "index_name": indexName,
            "directories_indexed": directoryResults.count,
            "total_files": indexPayload["total_files"] ?? directoryResults.first?["total_files"] ?? 0,
            "total_directories": indexPayload["total_directories"] ?? directoryResults.first?["total_directories"] ?? 0,
            "total_size": indexPayload["total_size"] ?? directoryResults.first?["total_size"] ?? "0 B",
        ]
        return jsonString(summary)
    }

    /// Index a single directory and return its structured summary.
    private static func indexSingleDirectory(
        path: String, maxDepth: Int, includeMetadata: Bool
    ) -> [String: Any] {
        var entries: [IndexEntry] = []
        var dirCount = 0
        var fileCount = 0
        var totalSize: Int64 = 0

        func walk(_ dirPath: String, currentDepth: Int) {
            guard maxDepth < 0 || currentDepth <= maxDepth else { return }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }

            for name in items.sorted() {
                let fullPath = (dirPath as NSString).appendingPathComponent(name)
                var isSubDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isSubDir) else { continue }

                if isSubDir.boolValue {
                    dirCount += 1
                    entries.append(IndexEntry(
                        name: name, path: fullPath, type: "directory",
                        depth: currentDepth, metadata: nil))
                    walk(fullPath, currentDepth: currentDepth + 1)
                } else {
                    fileCount += 1
                    var metadataSummary: String?
                    if includeMetadata, let meta = SpotlightMetadataExtractor.extract(for: fullPath) {
                        metadataSummary = SpotlightMetadataExtractor.summarize(meta)
                        if let size = meta.sizeBytes { totalSize += size }
                    } else if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                              let size = attrs[.size] as? Int64 {
                        totalSize += size
                    }
                    let ext = (name as NSString).pathExtension.lowercased()
                    entries.append(IndexEntry(
                        name: name, path: fullPath, type: ext.isEmpty ? "file" : ext,
                        depth: currentDepth, metadata: metadataSummary))
                }
            }
        }

        walk(path, currentDepth: 0)

        // Build tree representation
        var treeLines: [String] = [" \(path)"]
        func renderTree(_ dirPath: String, prefix: String, currentDepth: Int) {
            guard maxDepth < 0 || currentDepth <= maxDepth else { return }
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else { return }
            let sorted = items.sorted()
            for (i, name) in sorted.enumerated() {
                let fullPath = (dirPath as NSString).appendingPathComponent(name)
                var isSubDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isSubDir) else { continue }
                let isLast = i == sorted.count - 1
                let connector = isLast ? "└── " : "── "
                let childPrefix = isLast ? "    " : "│   "
                if isSubDir.boolValue {
                    treeLines.append("\(prefix)\(connector)📁 \(name)/")
                    renderTree(fullPath, prefix: prefix + childPrefix, currentDepth: currentDepth + 1)
                } else {
                    let icon = fileIcon(for: name)
                    var label = "\(prefix)\(connector)\(icon) \(name)"
                    if includeMetadata, let meta = SpotlightMetadataExtractor.extract(for: fullPath) {
                        let summary = SpotlightMetadataExtractor.summarize(meta)
                        if summary.count < 200 && summary != name {
                            label += " — \(summary)"
                        }
                    }
                    treeLines.append(label)
                }
            }
        }
        renderTree(path, prefix: "", currentDepth: 0)

        // File types summary
        var byType: [String: [String]] = [:]
        for entry in entries where entry.type != "directory" {
            byType[entry.type, default: []].append(entry.name)
        }
        var typeSummary: [String] = []
        for (type, files) in byType.sorted(by: { $0.value.count > $1.value.count }) {
            typeSummary.append("- \(type): \(files.count) file(s)")
        }

        return [
            "directory": path,
            "total_files": fileCount,
            "total_directories": dirCount,
            "total_size": formatBytes(totalSize),
            "tree": treeLines.joined(separator: "\n"),
            "file_types": typeSummary,
        ]
    }

    /// Parse a human-readable byte string back to Int64 (for combined totals).
    private static func parseBytes(_ s: String) -> Int64? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(" GB") {
            let val = Double(trimmed.dropLast(3)) ?? 0
            return Int64(val * 1024 * 1024 * 1024)
        }
        if trimmed.hasSuffix(" MB") {
            let val = Double(trimmed.dropLast(3)) ?? 0
            return Int64(val * 1024 * 1024)
        }
        if trimmed.hasSuffix(" KB") {
            let val = Double(trimmed.dropLast(3)) ?? 0
            return Int64(val * 1024)
        }
        if trimmed.hasSuffix(" B") {
            return Int64(trimmed.dropLast(2))
        }
        return Int64(trimmed)
    }

    /// Save a directory index to shared memory.
    static func saveIndex(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SaveIndexArgs.self),
              let index = args.index, !index.isEmpty,
              let name = args.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return errorJSON("save_index requires 'index' and 'name'")
        }

        let memoryStore = SimpleMemoryStore()
        let project = args.project?.trimmingCharacters(in: .whitespaces)

        do {
            // Sanitize the name for use as a file path component
            let sanitizedName = name.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: " ", with: "_")
                .lowercased()

            let uri: MaestroURI
            if let project, !project.isEmpty {
                uri = MaestroURI(kind: .knowledge, path: ["indexes", project, sanitizedName])
            } else {
                uri = MaestroURI(kind: .knowledge, path: ["indexes", sanitizedName])
            }

            try memoryStore.save(index, at: uri)
            return jsonString([
                "status": "saved",
                "name": name,
                "uri": "maestro://knowledge/\(uri.path.joined(separator: "/"))",
            ])
        } catch {
            return errorJSON("failed to save index: \(error.localizedDescription)")
        }
    }

    // MARK: - Document chunk indexing (RAG)

    private static let defaultChunkWords = 500
    private static let defaultOverlapWords = 100

    private static func chunkIndexBaseDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".ai-context")
            .appendingPathComponent("memory")
            .appendingPathComponent("knowledge")
            .appendingPathComponent("indices")
    }

    private static func chunkIndexDirectory(indexName: String, project: String?) -> URL {
        var dir = chunkIndexBaseDirectory()
        if let project = project?.trimmingCharacters(in: .whitespaces), !project.isEmpty {
            dir = dir.appendingPathComponent(sanitizeIndexComponent(project))
        }
        dir = dir.appendingPathComponent(sanitizeIndexComponent(indexName))
        return dir
    }

    private static func sanitizeIndexComponent(_ name: String) -> String {
        name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private static func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        let allowed = CharacterSet.letters.union(.decimalDigits)
        var words: [String] = []
        var current = ""
        for scalar in lower.unicodeScalars {
            if allowed.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                if current.count > 2 { words.append(current) }
                current = ""
            }
        }
        if !current.isEmpty && current.count > 2 { words.append(current) }
        return words
    }

    private static func normalizedTerm(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
    }

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

    private static func chunkText(_ text: String, chunkWords: Int, overlapWords: Int) -> [(text: String, startWord: Int, endWord: Int)] {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let stride = max(1, chunkWords - overlapWords)
        var chunks: [(text: String, startWord: Int, endWord: Int)] = []
        var start = 0
        while start < words.count {
            let end = min(start + chunkWords, words.count)
            let slice = words[start..<end]
            let chunkText = slice.joined(separator: " ")
            chunks.append((chunkText, start, end))
            if end == words.count { break }
            start += stride
        }
        return chunks
    }

    static func indexDocument(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: IndexDocumentArgs.self),
              let rawPaths = args.paths, !rawPaths.isEmpty,
              let indexName = args.index_name?.trimmingCharacters(in: .whitespaces), !indexName.isEmpty else {
            return errorJSON("index_document requires 'paths' array and 'index_name'")
        }

        let roots = authorizedRoots()
        var sourceFiles: [(path: String, actualPath: String)] = []
        for raw in rawPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let resolved = resolveAbsolute(trimmed) else {
                return errorJSON("index_document requires absolute paths (got '\(trimmed)')")
            }
            guard isAllowed(resolved, roots: roots) else { return denied(trimmed) }
            let actualPath = fuzzyResolve(resolved, wantDirectory: false) ?? resolved
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: actualPath, isDirectory: &isDir), !isDir.boolValue else {
                return errorJSON("no file at '\(resolved)'")
            }
            sourceFiles.append((trimmed, actualPath))
        }
        guard !sourceFiles.isEmpty else {
            return errorJSON("index_document: no valid file paths provided")
        }

        let chunkWords = max(50, args.chunk_words ?? defaultChunkWords)
        let overlapWords = max(0, args.overlap_words ?? defaultOverlapWords)
        let project = args.project?.trimmingCharacters(in: .whitespaces)

        let indexDir = chunkIndexDirectory(indexName: indexName, project: project)
        let chunksDir = indexDir.appendingPathComponent("chunks")
        try? FileManager.default.createDirectory(at: chunksDir, withIntermediateDirectories: true)

        var allChunks: [[String: Any]] = []
        var totalChunks = 0
        var skippedFiles: [String] = []

        for (originalPath, actualPath) in sourceFiles {
            guard let text = FileContentExtractor.extractText(from: actualPath), !text.isEmpty else {
                skippedFiles.append((actualPath as NSString).lastPathComponent)
                continue
            }
            let chunks = chunkText(text, chunkWords: chunkWords, overlapWords: overlapWords)
            let sourceFileName = (actualPath as NSString).lastPathComponent
            for (i, chunk) in chunks.enumerated() {
                totalChunks += 1
                let chunkId = "\(sourceFileName)_\(i)"
                let chunkFile = chunksDir.appendingPathComponent("\(chunkId).txt")
                try? chunk.text.write(to: chunkFile, atomically: true, encoding: .utf8)
                let meta: [String: Any] = [
                    "chunk_id": chunkId,
                    "source_path": actualPath,
                    "original_path": originalPath,
                    "source_file": sourceFileName,
                    "chunk_index": i,
                    "start_word": chunk.startWord,
                    "end_word": chunk.endWord,
                    "word_count": chunk.endWord - chunk.startWord,
                    "preview": String(chunk.text.prefix(200)),
                ]
                allChunks.append(meta)
            }
        }

        let metadata: [String: Any] = [
            "index_name": indexName,
            "project": project ?? NSNull(),
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "chunk_words": chunkWords,
            "overlap_words": overlapWords,
            "total_chunks": totalChunks,
            "source_files": sourceFiles.map { $0.actualPath },
            "skipped_files": skippedFiles,
            "chunks": allChunks,
        ]
        let metadataURL = indexDir.appendingPathComponent("metadata.json")
        if let data = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? data.write(to: metadataURL)
        }

        return jsonString([
            "status": "indexed",
            "index_name": indexName,
            "project": project ?? NSNull(),
            "total_chunks": totalChunks,
            "source_files": sourceFiles.count,
            "skipped_files": skippedFiles,
            "index_directory": indexDir.path,
        ])
    }

    private static func loadChunkMetadata(indexName: String, project: String?) -> [String: Any]? {
        let indexDir = chunkIndexDirectory(indexName: indexName, project: project)
        let metadataURL = indexDir.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return meta
    }

    private static func scoreChunk(_ chunkMeta: [String: Any], query: String) -> Double {
        guard let preview = chunkMeta["preview"] as? String else { return 0 }
        guard let sourceFile = chunkMeta["source_file"] as? String else { return 0 }
        let haystack = normalizedTerm(preview + " " + sourceFile)
        let queryTerms = tokenize(query)
        guard !queryTerms.isEmpty else { return 0 }

        var score = 0.0
        let haystackWords = tokenize(haystack)

        for term in queryTerms {
            // Exact match in preview or filename.
            if haystack.contains(term) {
                score += 10
                // Bonus if the whole query appears as a phrase.
                if queryTerms.count > 1, haystack.contains(normalizedTerm(query)) {
                    score += 20
                }
            } else {
                // Fuzzy match against individual words.
                for word in haystackWords {
                    let dist = levenshtein(term, word)
                    if dist <= 2 && dist < term.count {
                        score += Double(5 - dist)
                    }
                }
            }
        }

        // Boost when all query terms are present (AND match).
        let allPresent = queryTerms.allSatisfy { term in
            haystack.contains(term) || haystackWords.contains { levenshtein(term, $0) <= 2 }
        }
        if allPresent { score += Double(queryTerms.count * 5) }

        return score
    }

    static func searchChunks(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SearchChunksArgs.self),
              let indexName = args.index_name?.trimmingCharacters(in: .whitespaces), !indexName.isEmpty,
              let query = args.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return errorJSON("search_chunks requires 'index_name' and 'query'")
        }
        let project = args.project?.trimmingCharacters(in: .whitespaces)
        let topK = max(1, args.top_k ?? 10)

        guard let metadata = loadChunkMetadata(indexName: indexName, project: project),
              let chunks = metadata["chunks"] as? [[String: Any]] else {
            return errorJSON("no chunk index found for '\(indexName)'. Run index_document first.")
        }

        let scored = chunks.map { chunk -> (meta: [String: Any], score: Double) in
            (chunk, scoreChunk(chunk, query: query))
        }
        .filter { $0.score > 0 }
        .sorted { $0.score > $1.score }
        .prefix(topK)

        let results: [[String: Any]] = scored.map { chunk, score in
            [
                "chunk_id": chunk["chunk_id"] ?? "",
                "source_file": chunk["source_file"] ?? "",
                "source_path": chunk["source_path"] ?? "",
                "chunk_index": chunk["chunk_index"] ?? -1,
                "word_count": chunk["word_count"] ?? 0,
                "score": score,
                "preview": chunk["preview"] ?? "",
            ]
        }

        return jsonString([
            "index_name": indexName,
            "query": query,
            "total_indexed_chunks": chunks.count,
            "returned": results.count,
            "results": results,
        ])
    }

    static func readChunk(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadChunkArgs.self),
              let indexName = args.index_name?.trimmingCharacters(in: .whitespaces), !indexName.isEmpty,
              let chunkId = args.chunk_id?.trimmingCharacters(in: .whitespaces), !chunkId.isEmpty else {
            return errorJSON("read_chunk requires 'index_name' and 'chunk_id'")
        }
        let project = args.project?.trimmingCharacters(in: .whitespaces)
        let indexDir = chunkIndexDirectory(indexName: indexName, project: project)
        let chunkFile = indexDir.appendingPathComponent("chunks").appendingPathComponent("\(chunkId).txt")

        guard let data = try? Data(contentsOf: chunkFile),
              let text = String(data: data, encoding: .utf8) else {
            return errorJSON("chunk '\(chunkId)' not found in index '\(indexName)'")
        }

        return jsonString([
            "chunk_id": chunkId,
            "index_name": indexName,
            "source_file": chunkId.components(separatedBy: "_").dropLast().joined(separator: "_"),
            "word_count": tokenize(text).count,
            "text": text,
        ])
    }

    // MARK: - Spotlight search

    private struct SpotlightSearchArgs: Codable {
        let query: String?
        let scope: String?
        let detailed: Bool?
        let limit: Int?
    }

    static func spotlightSearch(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SpotlightSearchArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return errorJSON("spotlight_search requires 'query'")
        }

        let scope = args.scope?.trimmingCharacters(in: .whitespaces)
        let detailed = args.detailed ?? false
        let limit = args.limit ?? 50

        // Validate scope if provided
        if let scope = scope {
            guard let resolved = resolveAbsolute(scope) else {
                return errorJSON("spotlight_search 'scope' must be an absolute path (got '\(scope)')")
            }
            let roots = authorizedRoots()
            guard isAllowed(resolved, roots: roots) else {
                return denied(scope)
            }
        }

        // Perform the search
        let searchScope = scope ?? "/"
        let paths = SpotlightMetadataExtractor.search(in: searchScope, query: query)
        let limited = Array(paths.prefix(limit))

        if limited.isEmpty {
            return jsonString(["query": query, "scope": scope ?? "all", "count": 0, "results": []])
        }

        if detailed {
            // Extract full metadata for each result
            let batchResults = SpotlightMetadataExtractor.extractBatch(for: limited)
            let results: [[String: Any]] = limited.compactMap { path in
                guard let meta = batchResults[path] else { return nil }
                return SpotlightMetadataExtractor.detailedDict(meta)
            }
            return jsonString([
                "query": query,
                "scope": scope ?? "all",
                "count": results.count,
                "total_found": paths.count,
                "results": results,
            ])
        } else {
            // Return paths with basic summaries
            let results: [String] = limited.map { path in
                if let meta = SpotlightMetadataExtractor.extract(for: path) {
                    return SpotlightMetadataExtractor.summarize(meta)
                }
                return path
            }
            return jsonString([
                "query": query,
                "scope": scope ?? "all",
                "count": results.count,
                "total_found": paths.count,
                "results": results,
            ])
        }
    }

    // MARK: - Helpers

    private struct IndexEntry: Codable {
        let name: String
        let path: String
        let type: String
        let depth: Int
        let metadata: String?
    }

    private static func fileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "m", "mm", "h": return "📄"
        case "py", "js", "ts", "rb", "go", "rs": return "📄"
        case "json", "yaml", "yml", "toml", "xml": return "📋"
        case "md", "markdown", "txt", "rtf": return "📝"
        case "pdf": return "📕"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff": return "🖼️"
        case "mp4", "mov", "avi", "mkv": return "🎬"
        case "mp3", "wav", "aac", "flac": return "🎵"
        case "zip", "tar", "gz", "dmg", "pkg": return "📦"
        case "db", "sqlite", "sql": return "🗄️"
        default: return "📄"
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
    }
}
