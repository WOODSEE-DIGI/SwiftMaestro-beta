import Foundation

// MARK: - NETSCAPE Bookmark HTML import/export
//
// The universal bookmark interchange format ( Safari, Chrome, Firefox, Edge
// all export this exact structure):
//
//   <!DOCTYPE NETSCAPE-Bookmark-file-1>
//   <DL><p>
//     <DT><H3>Folder Name</H3>
//     <DL><p>
//       <DT><A HREF="https://..." ADD_DATE="...">Title</A>
//     </DL><p>
//   </DL><p>
//
// Favourites land in the special "Favorites" folder Safari uses; on import we
// map that folder to isFavorite = true (and Chrome's "Bookmarks bar" too).

extension BookmarkStore {

    // MARK: - Export

    func exportHTML() -> String {
        var lines: [String] = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- SwiftMaestro SwiftBrowser bookmarks -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]

        let favorites = bookmarks.filter(\.isFavorite)
        if !favorites.isEmpty {
            lines.append("    <DT><H3>Favorites</H3>")
            lines.append("    <DL><p>")
            for bookmark in favorites {
                lines.append("        \(Self.bookmarkLine(bookmark))")
            }
            lines.append("    </DL><p>")
        }

        let rootBookmarks = bookmarks.filter { !$0.isFavorite && $0.folder.isEmpty }
        for bookmark in rootBookmarks {
            lines.append("    \(Self.bookmarkLine(bookmark))")
        }

        for folder in folders {
            let folderBookmarks = bookmarks(in: folder).filter { !$0.isFavorite }
            guard !folderBookmarks.isEmpty else { continue }
            lines.append("    <DT><H3>\(Self.escaped(folder))</H3>")
            lines.append("    <DL><p>")
            for bookmark in folderBookmarks {
                lines.append("        \(Self.bookmarkLine(bookmark))")
            }
            lines.append("    </DL><p>")
        }

        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func bookmarkLine(_ bookmark: Bookmark) -> String {
        let addDate = Int(bookmark.createdAt.timeIntervalSince1970)
        let icon = bookmark.faviconURL.isEmpty ? "" : " ICON=\"\(escaped(bookmark.faviconURL))\""
        return "<DT><A HREF=\"\(escaped(bookmark.url))\" ADD_DATE=\"\(addDate)\"\(icon)>\(escaped(bookmark.title))</A>"
    }

    // MARK: - Import

    struct ImportResult: Sendable {
        let added: Int
        let skippedDuplicates: Int
        let folders: [String]
    }

    /// Parse a NETSCAPE bookmark file and merge into the store.
    /// Safari's "Favorites" and Chrome's "Bookmarks bar" folders import as
    /// favourites (shown in the bar); everything else keeps its folder.
    @discardableResult
    func importHTML(_ html: String) -> ImportResult {
        var added = 0
        var skipped = 0
        var seenFolders = Set<String>()
        var currentFolder = ""
        var currentFavorite = false

        // Walk the file tag by tag: <H3> opens a folder, <A> adds a bookmark.
        let tagPattern = #"<DT><H3[^>]*>(.*?)</H3>|<DT><A\s+([^>]*?)>(.*?)</A>|</DL>"#
        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return ImportResult(added: 0, skippedDuplicates: 0, folders: [])
        }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))

        for match in matches {
            // Folder open
            if match.range(at: 1).location != NSNotFound {
                let name = Self.unescaped(nsHTML.substring(with: match.range(at: 1)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = name.lowercased()
                if lower == "favorites" || lower == "favourites" || lower == "bookmarks bar" {
                    currentFavorite = true
                    currentFolder = ""
                } else {
                    currentFavorite = false
                    currentFolder = name
                    seenFolders.insert(name)
                }
                continue
            }
            // Folder close
            if match.range(at: 0).location != NSNotFound,
               nsHTML.substring(with: match.range(at: 0)).lowercased().hasPrefix("</dl") {
                currentFolder = ""
                currentFavorite = false
                continue
            }
            // Bookmark
            if match.range(at: 2).location != NSNotFound {
                let attrs = nsHTML.substring(with: match.range(at: 2))
                let title = Self.unescaped(nsHTML.substring(with: match.range(at: 3)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let href = Self.attribute("HREF", in: attrs),
                      let url = URL(string: href),
                      url.scheme == "http" || url.scheme == "https" else { continue }
                if isBookmarked(url: href) {
                    skipped += 1
                    continue
                }
                add(title: title, url: href,
                    folder: currentFolder, isFavorite: currentFavorite)
                added += 1
            }
        }
        return ImportResult(added: added, skippedDuplicates: skipped, folders: Array(seenFolders).sorted())
    }

    // MARK: - HTML utilities

    private static func attribute(_ name: String, in attrs: String) -> String? {
        let pattern = "\(name)\\s*=\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)),
              match.range(at: 1).location != NSNotFound else { return nil }
        return unescaped((attrs as NSString).substring(with: match.range(at: 1)))
    }

    private static func escaped(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
              .replacingOccurrences(of: "\"", with: "&quot;")
              .replacingOccurrences(of: "<", with: "&lt;")
              .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func unescaped(_ string: String) -> String {
        string.replacingOccurrences(of: "&quot;", with: "\"")
              .replacingOccurrences(of: "&lt;", with: "<")
              .replacingOccurrences(of: "&gt;", with: ">")
              .replacingOccurrences(of: "&amp;", with: "&")
    }
}
