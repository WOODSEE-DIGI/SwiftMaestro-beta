import Foundation

// MARK: - Bookmark Store
//
// SwiftBrowser bookmarks: folders, favourites bar flags, JSON persistence.
// Import/export speaks the universal NETSCAPE-Bookmark-file-1 HTML format —
// the same file Safari, Chrome, and Firefox all export — so bookmarks move
// freely between SwiftBrowser and the user's other browsers.

struct Bookmark: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var url: String
    /// Folder path segment, e.g. "Research" or "Research/AI". Empty = root.
    var folder: String
    /// Favourites show in the bar under the address field.
    var isFavorite: Bool
    var faviconURL: String
    var createdAt: Date

    init(id: UUID = UUID(), title: String, url: String, folder: String = "",
         isFavorite: Bool = false, faviconURL: String = "", createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.folder = folder
        self.isFavorite = isFavorite
        self.faviconURL = faviconURL
        self.createdAt = createdAt
    }

    var host: String {
        (URL(string: url)?.host ?? "").replacing(/^[Ww]{3}\./, with: "")
    }
}

@MainActor
@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var bookmarks: [Bookmark] = []

    private init() { load() }

    private var storeURL: URL {
        SwiftMaestroPaths.appSupportDir.appendingPathComponent("bookmarks.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - CRUD

    @discardableResult
    func add(title: String, url: String, folder: String = "", isFavorite: Bool = false) -> Bookmark {
        if let existing = bookmarks.first(where: { $0.url == url }) {
            return existing
        }
        let bookmark = Bookmark(
            title: title.isEmpty ? (URL(string: url)?.host ?? url) : title,
            url: url, folder: folder, isFavorite: isFavorite,
            faviconURL: Self.faviconURLString(for: url))
        bookmarks.append(bookmark)
        save()
        return bookmark
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    func update(_ bookmark: Bookmark) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index] = bookmark
        save()
    }

    func toggleFavorite(_ bookmark: Bookmark) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) else { return }
        bookmarks[index].isFavorite.toggle()
        save()
    }

    func isBookmarked(url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    var favorites: [Bookmark] {
        bookmarks.filter(\.isFavorite).sorted { $0.createdAt < $1.createdAt }
    }

    /// Distinct non-empty folder names, sorted.
    var folders: [String] {
        Array(Set(bookmarks.map(\.folder).filter { !$0.isEmpty })).sorted()
    }

    func bookmarks(in folder: String) -> [Bookmark] {
        bookmarks.filter { $0.folder == folder }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    static func faviconURLString(for pageURL: String) -> String {
        guard let host = URL(string: pageURL)?.host, !host.isEmpty else { return "" }
        return "https://\(host)/favicon.ico"
    }
}
