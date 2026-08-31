import Foundation
import GRDB

// MARK: - Memory FTS5 search engine

/// A local SQLite FTS5 cache over the shared AI Memory store
/// (`~/.ai-context/memory`, which now points at iCloud Drive via symlink).
///
/// The Markdown/JSON files in AI Memory remain the source of truth; this index
/// is a derived cache that lives in Application Support so a full-store scan
/// (surfaced through `SimpleMemoryStore.search`) becomes a sub-millisecond FTS
/// query instead of walking every file on every search.
///
/// Responsibilities:
///  - Maintain a `memory_files` table (path, kind, modified date, size) and a
///    `memory_fts` virtual table using FTS5 for fast full-text search.
///  - Reindex incrementally by comparing file modification dates each pass.
///  - Provide snippet generation from the stored content for search results.
///
/// Thread-safety: GRDB's `DatabaseQueue` is a value type safe to use across
/// actors; each public method runs its work inside a single `dbQueue` scope, so
/// the type itself is `Sendable`.
struct MemorySearchEngine: Sendable {

    /// Root of the shared AI Memory store. Matches `SimpleMemoryStore.baseDir`
    /// resolution: iCloud container first, `~/.ai-context/memory` fallback.
    static func resolveMemoryRoot() -> URL {
        let fm = FileManager.default
        if let iCloudContainer = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/SwiftMaestro/memory", isDirectory: true) {
            return iCloudContainer
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent(".ai-context/memory", isDirectory: true)
    }

    /// Path of the local index database under Application Support.
    static var indexURL: URL {
        SwiftMaestroPaths.appSupportDir
            .appendingPathComponent("memory-index.sqlite")
    }

    private static let maxFileSize = 2_000_000
    private var dbQueue: DatabaseQueue
    private let memoryRoot: URL

    // MARK: - Shared singleton

    /// Lazily-created, process-wide engine. Index reconstruction after the
    /// first `searchWithReindex` invalidates per-file staleness, so opening it
    /// is cheap and idempotent. `nil` if the index database can't be created
    /// (callers then fall back to the file-walking `SimpleMemoryStore.search`).
    nonisolated private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedInstance: MemorySearchEngine?

    static func shared() -> MemorySearchEngine? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let sharedInstance { return sharedInstance }
        guard let engine = try? MemorySearchEngine() else { return nil }
        sharedInstance = engine
        return engine
    }

    // MARK: - Init

    init(memoryRoot: URL = MemorySearchEngine.resolveMemoryRoot(),
         indexURL: URL = MemorySearchEngine.indexURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        self.memoryRoot = memoryRoot
        self.dbQueue = try DatabaseQueue(path: indexURL.path)

        do {
            try self.dbQueue.write { db in
                try Self.createSchema(in: db)
            }
        } catch {
            // If FTS5 is unavailable, fall back to a plain (unindexed) search
            // over the content column so the app never loses the ability to
            // search. The public methods handle this transparently.
            self.dbQueue = try DatabaseQueue(path: indexURL.path)
            try self.dbQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS memory_files (
                        path TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        mtime REAL NOT NULL,
                        size INTEGER NOT NULL,
                        content TEXT NOT NULL
                    ) STRICT
                    """)
            }
        }
    }

    // MARK: - Schema

    /// Bump when the schema/triggers change so a stale index from an older app
    /// build is rebuilt instead of silently querying a mismatched virtual table.
    private static let ftsSchemaVersion = "2" // external-content FTS + triggers

    private static func createSchema(in db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            ) STRICT
            """)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_files (
                path TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                content TEXT NOT NULL
            ) STRICT
            """)

        let storedVersion = try String.fetchOne(
            db, sql: "SELECT value FROM memory_meta WHERE key = ?", arguments: ["fts-schema-version"])

        // Drop and recreate the FTS artifacts if the schema is absent or stale.
        let needsRecreate = storedVersion != ftsSchemaVersion
        if needsRecreate {
            try db.execute(sql: "DROP TABLE IF EXISTS memory_fts")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memory_fts_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memory_fts_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS memory_fts_au")
        }

        // External-content FTS5 table: the authoritative tokens live in
        // `memory_files`; FTS is kept in sync by triggers, so every INSERT,
        // DELETE and UPDATE reflects through automatically.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
                path UNINDEXED,
                content,
                content = 'memory_files',
                content_rowid = 'rowid',
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS memory_fts_ai AFTER INSERT ON memory_files BEGIN
                INSERT INTO memory_fts(rowid, path, content)
                VALUES (new.rowid, new.path, new.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS memory_fts_ad AFTER DELETE ON memory_files BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, path, content)
                VALUES ('delete', old.rowid, old.path, old.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS memory_fts_au AFTER UPDATE ON memory_files BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, path, content)
                VALUES ('delete', old.rowid, old.path, old.content);
                INSERT INTO memory_fts(rowid, path, content)
                VALUES (new.rowid, new.path, new.content);
            END
            """)

        try db.execute(
            sql: "INSERT INTO memory_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: ["fts-schema-version", ftsSchemaVersion])

        // Rebuild the FTS index from scratch so it reflects current
        // `memory_files` contents (a no-op the very first time, when the table
        // is empty; `reindex()` fills it thereafter via the triggers).
        if needsRecreate {
            try db.execute(sql: "INSERT INTO memory_fts(memory_fts) VALUES ('rebuild')")
        }
    }

    // MARK: - Row model

    struct SearchResult: Sendable {
        let path: String
        let kind: String
        let snippet: String
    }

    /// Typed row backing the index. `kind` is null in the FTS table (derived
    /// from the path at load time), so it's optional here.
    private struct IndexedFile: Decodable, FetchableRecord, Sendable {
        var path: String
        var kind: String?
        var content: String
    }

    // MARK: - Indexing

    /// Rebuild the index for any files whose modification date or size changed
    /// since the last pass. Falls back gracefully on any per-file error so a
    /// single unreadable file never aborts the whole update.
    func reindex() throws {
        let fm = FileManager.default

        // Dereference the root first: `resolveMemoryRoot()` can return the
        // `~/.ai-context/memory` symlink that now points at iCloud Drive, and a
        // directory enumerator does not cross a symlink used as its start URL —
        // it would silently yield zero files. Resolving to the real destination
        // also makes the relative-path math below consistent (see `/private`).
        let resolvedRoot = memoryRoot.resolvingSymlinksInPath()
        guard let walker = fm.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }

        let rootPath = resolvedRoot.path

        var currentPaths = Set<String>()
        var batch: [(String, String, Double, Int, String)] = []

        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.pathExtension.lowercased() != "dat"
            else { continue }

            let fullPath = url.resolvingSymlinksInPath().path
            guard fullPath.hasPrefix(rootPath),
                  fullPath.count > rootPath.count
            else { continue }
            let rel = String(fullPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty, !rel.hasPrefix(".") else { continue }
            currentPaths.insert(rel)

            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? 0
            guard size <= Self.maxFileSize else { continue } // skip huge/binary files
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            let kind = Self.kindFor(url: url, relativePath: rel)
            batch.append((rel, kind, mtime, size, Self.redact(content)))
        }

        try dbQueue.write { db in
            let existing = try Set<String>(String.fetchCursor(
                db, sql: "SELECT path FROM memory_files"))
            let stale = existing.subtracting(currentPaths)
            if !stale.isEmpty {
                let placeholders = stale.map { _ in "?" }.joined(separator: ",")
                // Deleting from `memory_files` cascades into `memory_fts` via
                // the `memory_fts_ad` AFTER DELETE trigger.
                try db.execute(
                    sql: "DELETE FROM memory_files WHERE path IN (\(placeholders))",
                    arguments: StatementArguments(Array(stale)))
            }

            for (path, kind, mtime, size, content) in batch {
                let isSame = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM memory_files WHERE path = ? AND mtime = ? AND size = ?)",
                    arguments: [path, mtime, size]) ?? false
                if isSame { continue }
                // INSERT / ON CONFLICT UPDATE flows into `memory_fts` through
                // the AFTER INSERT / AFTER UPDATE triggers.
                try db.execute(
                    sql: """
                        INSERT INTO memory_files (path, kind, mtime, size, content)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(path) DO UPDATE SET
                            kind = excluded.kind,
                            mtime = excluded.mtime,
                            size = excluded.size,
                            content = excluded.content
                        """,
                    arguments: [path, kind, mtime, size, content])
            }
        }
    }

    /// How many files are currently indexed.
    var indexedCount: Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_files") ?? 0
        }) ?? 0
    }

    /// Convenience: bring the index up to date, then search. Best-effort —
    /// a reindex failure is swallowed so a healthy cache still serves results.
    func searchWithReindex(_ query: String, limit: Int = 20) -> [SearchResult] {
        try? reindex()
        return (try? search(query, limit: limit)) ?? []
    }

    // MARK: - Search

    /// Search the FTS index. Returns matches ranked by relevance, each with a
    /// snippet around the first match. Falls back to a full `LIKE` scan if FTS
    /// is unavailable.
    func search(_ query: String, limit: Int = 20) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let safeQuery = Self.ftsSafe(query: trimmed)

        if useFTS {
            let files: [IndexedFile] = try dbQueue.read { db in
                try IndexedFile.fetchAll(
                    db, sql: """
                        SELECT path, content
                        FROM memory_fts
                        WHERE memory_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                        """,
                    arguments: [safeQuery, limit])
            }
            return files.map { file in
                SearchResult(
                    path: file.path,
                    kind: Self.kindFromPath(file.path),
                    snippet: Self.snippetAround(file.content, around: trimmed, width: 160)
                )
            }
        } else {
            let like = "%\(trimmed)%"
            let files: [IndexedFile] = try dbQueue.read { db in
                try IndexedFile.fetchAll(
                    db, sql: """
                        SELECT path, kind, content
                        FROM memory_files
                        WHERE content LIKE ? ESCAPE '\\'
                        LIMIT ?
                        """,
                    arguments: [like, limit])
            }
            return files.map { file in
                SearchResult(
                    path: file.path,
                    kind: file.kind ?? Self.kindFromPath(file.path),
                    snippet: Self.snippetAround(file.content, around: trimmed, width: 160)
                )
            }
        }
    }

    /// Paths (already indexed) that have been deleted since last reindex — useful
    /// for a store that mirrors on-disk state.
    func allPaths() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM memory_files")
        }
    }

    // MARK: - FTS capability

    private var useFTS: Bool {
        (try? dbQueue.read { db in
            try db.tableExists("memory_fts")
        }) ?? false
    }

    // MARK: - Helpers

    private static func kindFor(url: URL, relativePath: String) -> String {
        let top = relativePath.split(separator: "/").first.map(String.init) ?? ""
        switch top {
        case "conversations", "context", "knowledge", "skills": return top
        default: return url.pathExtension.isEmpty ? "text" : url.pathExtension
        }
    }

    /// Escape user input so it can be used as an FTS5 MATCH query without
    /// syntax errors. Deals with quotes, dashes, and operator characters.
    private static func ftsSafe(query: String) -> String {
        // Wrap phrases; escape embedded double quotes.
        let parts = query
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { part -> String in
                let escaped = part.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
        return parts.joined(separator: " ")
    }

    /// Derive the memory kind from a relative path (e.g. "knowledge/foo.md").
    private static func kindFromPath(_ path: String) -> String {
        let top = path.split(separator: "/").first.map(String.init) ?? ""
        switch top {
        case "conversations", "context", "knowledge", "skills": return top
        default: return (path as NSString).pathExtension.isEmpty ? "text" : (path as NSString).pathExtension
        }
    }

    private static func snippetAround(_ content: String, around needle: String, width: Int) -> String {
        let collapsed = content.replacingOccurrences(of: "\n", with: " ")
        let lower = collapsed.lowercased()
        guard let r = lower.range(of: needle) else { return String(collapsed.prefix(width)) }
        let startOffset = max(0, lower.distance(from: lower.startIndex, to: r.lowerBound) - 40)
        let s = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
        let e = collapsed.index(s, offsetBy: min(width, collapsed.distance(from: s, to: collapsed.endIndex)))
        return String(collapsed[s..<e]).trimmingCharacters(in: .whitespaces)
    }

    /// Strip any known secret values before content is indexed (mirrors
    /// `SimpleMemoryStore.save`'s safety net).
    private static func redact(_ content: String) -> String {
        SecretRedactor.redact(content)
    }
}
