import SwiftUI

// MARK: - Favourites Bar
//
// Safari-style favourites strip under the address bar. Renders nothing when
// empty so it costs zero vertical space for users without favourites.

struct FavoritesBarView: View {
    let store: WebBrowserStore
    @State private var bookmarkStore = BookmarkStore.shared

    var body: some View {
        if !bookmarkStore.favorites.isEmpty {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(bookmarkStore.favorites) { bookmark in
                            Button {
                                Task { await store.loadURL(bookmark.url, in: store.selectedTab) }
                            } label: {
                                HStack(spacing: 6) {
                                    FaviconTile(bookmark: bookmark, size: 14)
                                    Text(bookmark.title)
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(bookmark.url)
                            .contextMenu {
                                Button("Open in New Tab") {
                                    Task {
                                        let tab = store.addTab()
                                        await store.loadURL(bookmark.url, in: tab)
                                    }
                                }
                                Button("Remove from Favourites") {
                                    bookmarkStore.toggleFavorite(bookmark)
                                }
                                Divider()
                                Button("Delete Bookmark", role: .destructive) {
                                    bookmarkStore.remove(bookmark)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                Divider()
            }
        }
    }
}

// MARK: - Favicon tile

/// Favicon image with a letter-tile fallback (offline-safe).
struct FaviconTile: View {
    let bookmark: Bookmark
    var size: CGFloat = 16

    var body: some View {
        if !bookmark.faviconURL.isEmpty, let url = URL(string: bookmark.faviconURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    letterTile
                }
            }
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: 3))
        } else {
            letterTile
        }
    }

    private var letterTile: some View {
        Text(String(bookmark.host.first ?? bookmark.title.first ?? "?").uppercased())
            .font(.system(size: size * 0.7, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.7), in: .rect(cornerRadius: 3))
    }
}
