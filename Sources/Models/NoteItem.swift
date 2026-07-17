import Foundation

// MARK: - Note item

/// A file or folder inside the SwiftMaestro Notes vault.
/// Mirrors a plain Markdown file on disk so the vault stays readable by
/// Obsidian, Logseq, Zettlr, or any other file-based note app.
struct NoteItem: Identifiable, Hashable, Sendable {
    /// Stable identifier derived from the file path so selection survives reloads.
    let id: String
    let url: URL
    let name: String
    let isFolder: Bool
    let modifiedAt: Date
    var children: [NoteItem]?

    init(url: URL, isFolder: Bool, modifiedAt: Date, children: [NoteItem]? = nil) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
        self.isFolder = isFolder
        self.modifiedAt = modifiedAt
        self.children = children
        self.id = url.path
    }

    /// True for `.md` files; false for folders and other files.
    var isNote: Bool { !isFolder && url.pathExtension.lowercased() == "md" }

    /// Display title derived from the filename.
    var title: String {
        isFolder ? name : url.deletingPathExtension().lastPathComponent
    }
}
