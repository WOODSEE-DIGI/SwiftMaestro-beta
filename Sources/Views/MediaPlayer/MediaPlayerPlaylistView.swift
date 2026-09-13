import SwiftUI

// MARK: - Media Player Playlist View
//
// Scrollable playlist with now-playing highlight, drag-reorder,
// context menu actions, and BTOP+ retro styling.

struct MediaPlayerPlaylistView: View {
    @Environment(ThemeStore.self) private var theme
    @Bindable var queue: MediaPlayerQueue
    let onPlayEntry: (Int) -> Void
    /// Open the file picker (wired to the parent view's fileImporter).
    var onOpenFiles: () -> Void = {}
    /// Open the playlist import picker (M3U/M3U8, PLS, iTunes/Music XML).
    var onImportPlaylist: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet")
                    .foregroundStyle(theme.accent.opacity(0.6))
                Text("PLAYLIST")
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.accent.opacity(0.6))
                Spacer()
                Text("\(queue.count) TRACKS")
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.accent.opacity(0.4))
                Button {
                    onImportPlaylist()
                } label: {
                    Image(systemName: "music.note.list.badge.plus")
                        .font(.caption2)
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .help("Import playlist from Apple Music, iTunes, or an M3U/PLS file")
                if !queue.isEmpty {
                    Button {
                        queue.clear()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
                .background(theme.accent.opacity(0.2))

            // Track list
            if queue.isEmpty {
                emptyState
            } else {
                trackList
            }
        }
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No tracks")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Button {
                onOpenFiles()
            } label: {
                Text("Open files…")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            Button {
                onImportPlaylist()
            } label: {
                Text("Import playlist…")
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Import an M3U/M3U8, PLS, or iTunes/Music XML playlist")
            Text("or drag media anywhere on this panel")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary.opacity(0.6))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Track List

    private var trackList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(queue.entries.enumerated()), id: \.element.id) { idx, entry in
                        trackRow(entry: entry, index: idx)
                            .id(entry.id)
                    }
                }
            }
            .onChange(of: queue.currentIndex) { _, newIdx in
                if let idx = newIdx, idx < queue.entries.count {
                    withAnimation {
                        proxy.scrollTo(queue.entries[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Track Row

    private func trackRow(entry: MediaPlayerQueue.Entry, index: Int) -> some View {
        let isCurrentTrack = queue.currentIndex == index
        return trackRowContent(entry: entry, index: index, isCurrentTrack: isCurrentTrack)
    }

    @ViewBuilder
    private func trackRowContent(entry: MediaPlayerQueue.Entry, index: Int, isCurrentTrack: Bool) -> some View {

        HStack(spacing: 8) {
            // Playing indicator
            if isCurrentTrack {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
                    .frame(width: 14)
            } else {
                Text("\(index + 1)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }

            // Track info
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.caption.monospaced())
                    .foregroundStyle(isCurrentTrack ? theme.accent : .primary)
                    .lineLimit(1)

                if let artist = entry.artist {
                    Text(artist)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Duration
            if let duration = entry.duration {
                Text(formatDuration(duration))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isCurrentTrack
                ? theme.accent.opacity(0.08)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onPlayEntry(index)
        }
        .contextMenu {
            Button("Play") { onPlayEntry(index) }
            Button("Play from Here") {
                // Play this and all after
                for i in index..<queue.count {
                    if let url = queue.playIndex(i) {
                        onPlayEntry(i)
                        break
                    }
                }
            }
            Divider()
            Button("Remove") {
                queue.remove(id: entry.id)
            }
            Button("Remove All After") {
                // Remove entries after this index
                let idsToRemove = queue.entries[(index + 1)...].map(\.id)
                for id in idsToRemove {
                    queue.remove(id: id)
                }
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
