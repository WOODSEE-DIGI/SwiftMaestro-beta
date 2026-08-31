import Foundation

// MARK: - Memory Import Service
//
// Reusable import route that persists files into the shared memory store at
// `~/.ai-context/memory` (backed by `SimpleMemoryStore`), so everything lands in
// the one store that `memory_search` indexes and all local AI tools read.
//
// Both the Settings → Context "Import Folder Into Memory" feature and chat
// drag-and-drop attachments funnel through this same service, so a document the
// user drops into a chat and a folder they import in Settings end up stored in
// exactly the same way.

/// The destination namespace for an import. Controls which sub-tree of the
/// shared memory store receives the files.
enum MemoryImportDestination: Sendable {
    /// Durable, shared knowledge base: `knowledge/imports/...`. Readable by all
    /// local AI tools. Used by the "Maestro (parent)" scope and chat
    /// attachments (scoped further by agent name).
    case knowledge
    /// Scoped to a specific agent project: `context/<project>/imports/...`.
    /// Used by the "Agent project (child)" scope.
    case project(String)
}

extension MemoryImportDestination {
    /// The relative folder path underneath the store's kind directory where
    /// imports are written. The kind directory itself is chosen here too.
    var kind: MaestroURI.Kind {
        switch self {
        case .knowledge: return .knowledge
        case .project: return .context
        }
    }

    var subdirectory: String {
        switch self {
        case .knowledge:
            return "imports"
        case .project(let name):
            let safe = MemoryImportService.sanitizeComponent(name)
            return "imports/\(safe)"
        }
    }
}

/// Coordinates imports into shared memory. An actor so multi-megabyte folder
/// scans and byte copies run off the main actor without blocking the UI, while
/// still safely serialising concurrent imports (e.g. a folder import in
/// Settings racing a chat attachment import).
actor MemoryImportService {

    static let shared = MemoryImportService()

    private let store: SimpleMemoryStore
    private let fileManager = FileManager.default

    /// - Parameter basePath: Optional override for the memory store root. Tests
    ///   pass a temporary directory here so imports land in isolation; production
    ///   uses the default shared `~/.ai-context/memory` store.
    init(basePath: URL? = nil) {
        if let basePath {
            self.store = SimpleMemoryStore(basePath: basePath)
        } else {
            self.store = SimpleMemoryStore()
        }
    }

    /// Progress callback, invoked from the actor (not the main thread).
    /// `scanned` = files examined, `written` = files persisted so far.
    typealias ProgressHandler = @Sendable (_ scanned: Int, _ written: Int) -> Void

    // MARK: - Folder import

    /// Recursively import every file under `url` into the given destination,
    /// preserving the source's relative folder structure. Returns the number of
    /// files written.
    @discardableResult
    func importFolder(
        at url: URL,
        destination: MemoryImportDestination,
        progress: ProgressHandler? = nil
    ) async throws -> Int {
        // Resolve the input path defensively: typed paths in Settings may be
        // relative (anchor to home), contain `~`, trailing slashes, or point at
        // a symlink — normalize up front so a valid folder is never misjudged
        // as "not a folder" (which the old code surfaced as a bare error 0).
        let rootURL = Self.normalizedFolderURL(from: url)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MemoryImportError.notAFolder(url.path)
        }

        // Security-scoped access for iCloud/user-selected folders.
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        var scanned = 0
        var written = 0
        let destBase = destinationDirectory(for: destination)

        try FileManager.default.createDirectory(
            at: destBase, withIntermediateDirectories: true)

        // Enumerate synchronously into an array of (relativePath, url). Using
        // `subpathsOfDirectory` returns relative paths directly (no root-prefix
        // matching), which avoids macOS `/var` vs `/private/var` symlink
        // mismatches between the root URL and the enumerated child URLs.
        let files = Self.enumerateRelativeFiles(under: rootURL)
        guard !files.isEmpty else {
            // Empty folder is not a hard error — it's a valid (no-op) import.
            return 0
        }

        for file in files {
            scanned += 1
            do {
                try self.copyFile(at: file.url, to: destBase, relative: file.relative)
                written += 1
            } catch {
                // Keep going on a single unreadable file; surface a lightweight
                // note via NSLog rather than aborting the whole import.
                NSLog("[MemoryImport] skipped \(file.url.path): \(error.localizedDescription)")
            }
            progress?(scanned, written)
        }

        return written
    }

    /// Synchronously walk `root` and return all regular, non-hidden files as
    /// (relativePath, url) pairs. Relative paths come straight from
    /// `subpathsOfDirectory`, so they always align with the root URL regardless
    /// of filesystem symlink resolution. Runs off the actor (nonisolated).
    private static nonisolated func enumerateRelativeFiles(
        under root: URL
    ) -> [(relative: String, url: URL)] {
        let fm = FileManager.default
        let subpaths: [String]
        do {
            subpaths = try fm.subpathsOfDirectory(atPath: root.path)
        } catch {
            return []
        }

        var out: [(relative: String, url: URL)] = []
        for sub in subpaths {
            let full = root.appendingPathComponent(sub)
            let isRegular = (try? full.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            guard isRegular, !shouldSkip(full) else { continue }
            out.append((sub, full))
        }
        return out
    }

    /// Turn a user-typed path into an absolute, on-disk folder URL. Handles
    /// `~`/`~user` prefixes, relative paths (anchored to the home directory),
    /// stray components, and trailing slashes, and resolves symlinks so the
    /// resulting path is the one the file system will report back from
    /// enumeration. Only called from `importFolder`; safe to run off the actor.
    private static nonisolated func normalizedFolderURL(from url: URL) -> URL {
        var path = url.path
        path = (path as NSString).expandingTildeInPath
        if path.hasPrefix("/") == false {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            path = (home as NSString).appendingPathComponent(path)
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        return standardized.resolvingSymlinksInPath()
    }

    // MARK: - Single file import

    /// Import a single file from disk into the destination, preserving its
    /// filename (optionally nested under a `subfolder`). Returns 1 on success.
    @discardableResult
    func importFile(
        at url: URL,
        destination: MemoryImportDestination,
        subfolder: String? = nil
    ) async throws -> Int {
        let destBase = destinationDirectory(for: destination)
        let rel: String
        if let subfolder {
            rel = "\(Self.sanitizeRelativePath(subfolder))/\(url.lastPathComponent)"
        } else {
            rel = url.lastPathComponent
        }
        try copyFile(at: url, to: destBase, relative: rel)
        return 1
    }

    /// Import in-memory bytes (e.g. a pasteboard/dropped image) into the
    /// destination under `filename`. Returns 1 on success.
    @discardableResult
    func importData(
        _ data: Data,
        filename: String,
        destination: MemoryImportDestination,
        subfolder: String? = nil
    ) async throws -> Int {
        let destBase = destinationDirectory(for: destination)
        let rel: String
        if let subfolder {
            rel = "\(Self.sanitizeRelativePath(subfolder))/\(Self.sanitizeComponent(filename))"
        } else {
            rel = Self.sanitizeComponent(filename)
        }
        let fileURL = destBase.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return 1
    }

    // MARK: - Totalling

    /// Count regular files currently in the memory store under the destination.
    func countFiles(in destination: MemoryImportDestination) -> Int {
        store.countEntries(kind: destination.kind, pathPrefix: destination.subdirectory)
    }

    // MARK: - Helpers

    /// Resolve the absolute directory for a destination inside the store.
    private func destinationDirectory(for destination: MemoryImportDestination) -> URL {
        store.directory(for: destination.kind)
            .appendingPathComponent(destination.subdirectory, isDirectory: true)
    }

    /// Copy a single file preserving bytes (no read-into-memory for large files).
    private func copyFile(at source: URL, to baseDir: URL, relative: String) throws {
        let target = baseDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Overwrite if it already exists (idempotent re-import of a folder).
        if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }

    /// Sanitize a multi-component relative path, cleaning each segment so no
    /// segment can escape the intended namespace (slashes are preserved as
    /// structural separators between components).
    static func sanitizeRelativePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { sanitizeComponent(String($0)) }
            .joined(separator: "/")
    }

    /// Skip files that add no memory value (system cruft, symlinks, lock files).
    private static func shouldSkip(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == ".DS_Store" || name.hasPrefix(".") { return true }
        let lower = name.lowercased()
        if lower.hasSuffix(".lock") || lower.hasSuffix(".tmp") { return true }
        // Don't pull in directories-as-files; only regular files were requested.
        return false
    }

    /// Make a path component safe to use inside the file system (strip slashes
    /// and path separators that could escape the intended namespace).
    static func sanitizeComponent(_ component: String) -> String {
        let cleaned = component.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "import" : trimmed
    }
}

enum MemoryImportError: Error, LocalizedError, CustomStringConvertible {
    case notAFolder(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notAFolder(let path): return "Not a folder: \(path)"
        case .unreadable(let path): return "Cannot read folder: \(path)"
        }
    }

    var description: String {
        errorDescription ?? "Memory import failed"
    }
}
