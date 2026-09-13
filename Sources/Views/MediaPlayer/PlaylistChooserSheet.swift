import SwiftUI

/// Sheet that lets the user pick one playlist from an imported iTunes /
/// Apple Music library XML before adding its tracks to the Media Player queue.
struct PlaylistChooserSheet: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let playlists: [ImportedPlaylist]
    let onAdd: (ImportedPlaylist) -> Void

    var body: some View {
        NavigationStack {
            List(playlists) { playlist in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.name)
                            .font(.headline)
                        Text("\(playlist.tracks.count) tracks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        onAdd(playlist)
                        dismiss()
                    } label: {
                        Text("Add")
                            .font(.caption.monospaced().weight(.medium))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(theme.accent.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("Choose Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

#Preview {
    PlaylistChooserSheet(playlists: [
        ImportedPlaylist(name: "Driving", tracks: [
            URL(fileURLWithPath: "/tmp/01.mp3"),
            URL(fileURLWithPath: "/tmp/02.mp3")
        ]),
        ImportedPlaylist(name: "Workout", tracks: [
            URL(fileURLWithPath: "/tmp/03.mp3")
        ])
    ]) { _ in }
    .environment(ThemeStore())
}
