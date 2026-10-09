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

    /// When true, the note/folder is reserved for agents (e.g. the AI Memory
    /// store). Notes.md reads it freely but refuses to create, edit, rename, or
    /// delete without the user explicitly unlocking after a backup warning.
    var isReadOnly = false

    /// Optional display title override. Used for generated search results (e.g.
    /// plan mirrors) where the filename is not human-readable.
    var displayTitle: String? = nil

    init(url: URL, isFolder: Bool, modifiedAt: Date, children: [NoteItem]? = nil) {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent
        self.isFolder = isFolder
        self.modifiedAt = modifiedAt
        self.children = children
        self.id = url.path
    }

    static func == (lhs: NoteItem, rhs: NoteItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// True for `.md` files; false for folders and other files.
    var isNote: Bool { !isFolder && url.pathExtension.lowercased() == "md" }

    /// True for non-note, non-folder files (clip assets: html/json/images/txt).
    var isAsset: Bool { !isFolder && !isNote }

    enum AssetKind: String, Sendable {
        case html, json, image, text, other
    }

    /// How the editor should render this file when it's not a note.
    var assetKind: AssetKind {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return .html
        case "json": return .json
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic": return .image
        case "txt": return .text
        default: return .other
        }
    }

    /// Display title derived from the filename, with an optional override for
    /// generated results where the filename is not meaningful.
    var title: String {
        if let displayTitle { return displayTitle }
        return isFolder ? name : url.deletingPathExtension().lastPathComponent
    }
}
