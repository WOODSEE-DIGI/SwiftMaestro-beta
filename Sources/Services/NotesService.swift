import Foundation

// MARK: - Notes service

/// File-system operations for the SwiftMaestro Notes vault.
/// All notes are plain Markdown files (`.md`) stored in a user-configurable folder.
/// The default vault lives under `~/Documents/SwiftMaestro Notes/`.
/// Reads/writes are wrapped in `NSFileCoordinator` so the vault can safely live in
/// iCloud Drive and sync across devices.
actor NotesService {

    let vaultURL: URL

    init(vaultURL: URL) {
        self.vaultURL = vaultURL
    }

    /// Ensure the vault root exists.
    func ensureVault() throws {
        try coordinate(writing: vaultURL) { url in
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }
    }

    /// List all note items inside a folder, recursively for folders.
    func listDirectory(at url: URL) throws -> [NoteItem] {
        try coordinate(reading: url) { url in
            let fm = FileManager.default
            let contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: .skipsHiddenFiles)

            var items: [NoteItem] = []
            for itemURL in contents {
                let resourceValues = try itemURL.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                let isDirectory = resourceValues.isDirectory ?? false
                let modified = resourceValues.contentModificationDate ?? Date()

                if isDirectory {
                    let children = try listDirectory(at: itemURL)
                    items.append(NoteItem(url: itemURL, isFolder: true, modifiedAt: modified, children: children))
                } else if Self.isListableFile(itemURL) {
                    items.append(NoteItem(url: itemURL, isFolder: false, modifiedAt: modified))
                }
            }

            return items.sorted {
                if $0.isFolder != $1.isFolder { return $0.isFolder && !$1.isFolder }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
        }
    }

    /// Notes (.md) plus clip-asset artifacts (reader.html, snapshot.html,
    /// capture-metadata.json, images) — the Web Clipper writes a folder of
    /// forensic files beside each note and they must be browsable in the panel.
    private nonisolated static func isListableFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return true }
        return ["md", "html", "json", "txt",
                "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic"].contains(ext)
    }

    /// Read the contents of a note file.
    func readFile(at url: URL) throws -> String {
        try coordinate(reading: url) { url in
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NotesServiceError.fileNotFound(url)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// Write contents to a note file, creating it if necessary.
    func writeFile(at url: URL, content: String) throws {
        let parent = url.deletingLastPathComponent()
        try coordinate(writing: parent) { parentURL in
            try FileManager.default.createDirectory(
                at: parentURL, withIntermediateDirectories: true, attributes: nil)
        }
        try coordinate(writing: url, options: .forReplacing) { targetURL in
            try content.write(to: targetURL, atomically: true, encoding: .utf8)
        }
    }

    /// Create a new Markdown note in the given folder.
    /// Sanitizes the name and appends `.md` if missing.
    func createNote(named name: String, in folder: URL) throws -> URL {
        let safeName = sanitized(name)
        var fileName = safeName
        if !fileName.lowercased().hasSuffix(".md") { fileName += ".md" }
        let target = folder.appendingPathComponent(fileName)
        try coordinate(writing: folder) { folderURL in
            let targetInCoord = folderURL.appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: targetInCoord.path) {
                try "# \(safeName)\n\n".write(to: targetInCoord, atomically: true, encoding: .utf8)
            }
        }
        return target
    }

    /// Create a clipped note in the given folder, generating a unique filename
    /// and writing the supplied Markdown content.
    func createClippedNote(title: String, content: String, in folder: URL) throws -> URL {
        let safeTitle = sanitized(title)
        let baseName = safeTitle.isEmpty ? "Clipped" : safeTitle
        let datePrefix = ISO8601DateFormatter().string(from: Date())
        let fileName = "\(datePrefix) \(baseName).md"
        let target = folder.appendingPathComponent(fileName)
        try writeFile(at: target, content: content)
        return target
    }

    /// Create a new folder in the given parent folder.
    func createFolder(named name: String, in folder: URL) throws -> URL {
        let safeName = sanitized(name)
        let target = folder.appendingPathComponent(safeName)
        try coordinate(writing: target) { targetURL in
            try FileManager.default.createDirectory(
                at: targetURL, withIntermediateDirectories: false, attributes: nil)
        }
        return target
    }

    /// Delete a note or folder.
    func delete(item: NoteItem) throws {
        try coordinate(writing: item.url, options: .forDeleting) { url in
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Rename a note or folder.
    func rename(item: NoteItem, to newName: String) throws -> URL {
        let safeName = sanitized(newName)
        let parent = item.url.deletingLastPathComponent()
        let newURL = parent.appendingPathComponent(safeName)
        guard item.url.path != newURL.path else { return item.url }
        try coordinate(reading: item.url, writing: newURL) { sourceURL, destinationURL in
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                throw NotesServiceError.alreadyExists(newURL)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        }
        return newURL
    }

    /// Search note titles and contents for a query string.
    func search(query: String, scope: URL? = nil) throws -> [NoteItem] {
        let base = scope ?? vaultURL
        let lower = query.lowercased()
        var matches: [NoteItem] = []
        try coordinate(reading: base) { baseURL in
            try enumerateMarkdownFiles(at: baseURL) { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                if name.contains(lower) {
                    matches.append(NoteItem(url: url, isFolder: false, modifiedAt: Date()))
                    return
                }
                if let content = try? String(contentsOf: url, encoding: .utf8),
                   content.lowercased().contains(lower) {
                    matches.append(NoteItem(url: url, isFolder: false, modifiedAt: Date()))
                }
            }
        }
        return matches.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - iCloud-safe file coordination

    private func coordinate<T>(reading url: URL, options: NSFileCoordinator.ReadingOptions = [], _ block: (URL) throws -> T) throws -> T {
        var coordinatorError: NSError?
        var result: T?
        var thrownError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: options, error: &coordinatorError) { coordinatedURL in
            do {
                result = try block(coordinatedURL)
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if let coordinatorError { throw coordinatorError }
        return result!
    }

    private func coordinate<T>(writing url: URL, options: NSFileCoordinator.WritingOptions = [], _ block: (URL) throws -> T) throws -> T {
        var coordinatorError: NSError?
        var result: T?
        var thrownError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinatorError) { coordinatedURL in
            do {
                result = try block(coordinatedURL)
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if let coordinatorError { throw coordinatorError }
        return result!
    }

    private func coordinate<T>(reading readURL: URL, options readingOptions: NSFileCoordinator.ReadingOptions = [], writing writeURL: URL, options writingOptions: NSFileCoordinator.WritingOptions = [], _ block: (URL, URL) throws -> T) throws -> T {
        var coordinatorError: NSError?
        var result: T?
        var thrownError: Error?
        NSFileCoordinator().coordinate(readingItemAt: readURL, options: readingOptions, writingItemAt: writeURL, options: writingOptions, error: &coordinatorError) { sourceURL, destinationURL in
            do {
                result = try block(sourceURL, destinationURL)
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        if let coordinatorError { throw coordinatorError }
        return result!
    }

    // MARK: - Helpers

    private func enumerateMarkdownFiles(at url: URL, handler: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)
        for item in contents {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                try enumerateMarkdownFiles(at: item, handler: handler)
            } else if item.pathExtension.lowercased() == "md" {
                try handler(item)
            }
        }
    }

    private func sanitized(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return trimmed.components(separatedBy: invalid).joined(separator: "-")
    }
}

// MARK: - Errors

enum NotesServiceError: LocalizedError {
    case fileNotFound(URL)
    case alreadyExists(URL)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "File not found: \(url.lastPathComponent)"
        case .alreadyExists(let url): return "An item named '\(url.lastPathComponent)' already exists."
        }
    }
}
