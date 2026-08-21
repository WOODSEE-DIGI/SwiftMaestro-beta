import SwiftUI
import AppKit

// MARK: - Bookmarks Manager Popover
//
// Full bookmark management from the browser toolbar: folder-grouped list,
// add current page, favourite toggles, delete, and NETSCAPE HTML
// import/export (the format Safari/Chrome/Firefox export).

struct BookmarksPopoverView: View {
    let store: WebBrowserStore
    @State private var bookmarkStore = BookmarkStore.shared
    @State private var search = ""
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 400)
        .frame(maxHeight: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.fill")
                .foregroundStyle(Color.accentColor)
            Text("Bookmarks")
                .font(.headline)
            Spacer()
            Button {
                addCurrentPage()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Bookmark current page")
            .disabled(store.selectedTab?.currentURL == nil)
        }
        .padding(12)
    }

    // MARK: - List

    private var filtered: [Bookmark] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return bookmarkStore.bookmarks }
        return bookmarkStore.bookmarks.filter {
            $0.title.lowercased().contains(query)
                || $0.url.lowercased().contains(query)
                || $0.folder.lowercased().contains(query)
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search bookmarks…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No Bookmarks" : "No Matches",
                    systemImage: "book",
                    description: Text(search.isEmpty
                        ? "Star a page or import bookmarks to get started."
                        : "No bookmarks match \"\(search)\".")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        let favorites = filtered.filter(\.isFavorite)
                        if !favorites.isEmpty {
                            bookmarkSection(title: "Favourites", systemImage: "star.fill", bookmarks: favorites)
                        }
                        let root = filtered.filter { !$0.isFavorite && $0.folder.isEmpty }
                        if !root.isEmpty {
                            bookmarkSection(title: "Bookmarks", systemImage: "book", bookmarks: root)
                        }
                        ForEach(bookmarkStore.folders.filter { folder in
                            filtered.contains { $0.folder == folder && !$0.isFavorite }
                        }, id: \.self) { folder in
                            let inFolder = filtered.filter { $0.folder == folder && !$0.isFavorite }
                            bookmarkSection(title: folder, systemImage: "folder", bookmarks: inFolder)
                        }
                    }
                }
            }
        }
    }

    private func bookmarkSection(title: String, systemImage: String, bookmarks: [Bookmark]) -> some View {
        Section {
            ForEach(bookmarks) { bookmark in
                bookmarkRow(bookmark)
                Divider().padding(.leading, 34)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption2)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .textCase(.none)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
        }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 8) {
            FaviconTile(bookmark: bookmark, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(bookmark.host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                bookmarkStore.toggleFavorite(bookmark)
            } label: {
                Image(systemName: bookmark.isFavorite ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(bookmark.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(bookmark.isFavorite ? "Remove from Favourites" : "Show in Favourites bar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await store.loadURL(bookmark.url, in: store.selectedTab) }
        }
        .contextMenu {
            Button("Open") {
                Task { await store.loadURL(bookmark.url, in: store.selectedTab) }
            }
            Button("Open in New Tab") {
                Task {
                    let tab = store.addTab()
                    await store.loadURL(bookmark.url, in: tab)
                }
            }
            Divider()
            Button(bookmark.isFavorite ? "Remove from Favourites" : "Add to Favourites") {
                bookmarkStore.toggleFavorite(bookmark)
            }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bookmark.url, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) {
                bookmarkStore.remove(bookmark)
            }
        }
    }

    // MARK: - Footer (import/export)

    private var footer: some View {
        HStack {
            Button {
                importBookmarks()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
                    .font(.caption)
            }
            .help("Import a bookmarks HTML file (Safari, Chrome, Firefox export format)")

            Button {
                exportBookmarks()
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .help("Export bookmarks as HTML (readable by Safari, Chrome, Firefox)")
            .disabled(bookmarkStore.bookmarks.isEmpty)

            Spacer()
            Text("\(bookmarkStore.bookmarks.count) saved")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, -22)
            }
        }
    }

    // MARK: - Actions

    private func addCurrentPage() {
        guard let tab = store.selectedTab,
              let url = tab.currentURL?.absoluteString else { return }
        bookmarkStore.add(title: tab.title, url: url)
        showStatus("Bookmarked \(tab.title)")
    }

    private func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a bookmarks HTML file exported from Safari, Chrome, or Firefox"
        guard panel.runModal() == .OK, let url = panel.url,
              let html = try? String(contentsOf: url, encoding: .utf8) else { return }
        let result = bookmarkStore.importHTML(html)
        var parts = ["\(result.added) imported"]
        if result.skippedDuplicates > 0 { parts.append("\(result.skippedDuplicates) duplicates skipped") }
        showStatus(parts.joined(separator: ", "))
    }

    private func exportBookmarks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "SwiftMaestro Bookmarks.html"
        panel.message = "Export bookmarks as HTML"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try bookmarkStore.exportHTML().write(to: url, atomically: true, encoding: .utf8)
            showStatus("Exported to \(url.lastPathComponent)")
        } catch {
            showStatus("Export failed: \(error.localizedDescription)")
        }
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusMessage == message { statusMessage = nil }
        }
    }
}
