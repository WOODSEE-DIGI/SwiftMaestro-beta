import SwiftUI

// MARK: - Media Player Info View
//
// Displays technical metadata about the currently loaded media in a
// BTOP+ retro monospace readout format.

struct MediaPlayerInfoView: View {
    let mediaInfo: MediaInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "info.circle")
                    .foregroundStyle(RetroPalette.green.opacity(0.6))
                Text("MEDIA INFO")
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.green.opacity(0.6))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
                .background(RetroPalette.green.opacity(0.2))

            // Info grid
            VStack(alignment: .leading, spacing: 4) {
                if let title = mediaInfo.title {
                    infoRow(label: "TITLE", value: title)
                }
                if let artist = mediaInfo.artist {
                    infoRow(label: "ARTIST", value: artist)
                }
                if let album = mediaInfo.album {
                    infoRow(label: "ALBUM", value: album)
                }

                if mediaInfo.title != nil || mediaInfo.artist != nil {
                    Divider().background(RetroPalette.green.opacity(0.15))
                }

                infoRow(label: "FORMAT", value: mediaInfo.displayFormat)
                infoRow(label: "SIZE", value: mediaInfo.displayFileSize)

                if mediaInfo.hasVideo {
                    infoRow(label: "RES", value: mediaInfo.displayResolution)
                }

                infoRow(label: "SAMPLE RATE", value: mediaInfo.displaySampleRate)
                infoRow(label: "CHANNELS", value: mediaInfo.displayChannels)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(RetroPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(RetroPalette.green.opacity(0.35), lineWidth: 1)
        )
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(RetroPalette.green.opacity(0.5))
                .frame(width: 85, alignment: .trailing)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(RetroPalette.green.opacity(0.9))
                .lineLimit(2)
            Spacer()
        }
    }
}

// MARK: - Now Playing Mini Card

/// Compact now-playing display showing artwork, title, and artist.
struct MediaPlayerNowPlayingCard: View {
    let mediaInfo: MediaInfo
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Artwork or placeholder
            if let artwork = mediaInfo.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(RetroPalette.dim)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.title3)
                            .foregroundStyle(RetroPalette.green.opacity(0.4))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(mediaInfo.displayTitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(RetroPalette.green)
                    .lineLimit(1)

                Text(mediaInfo.displayArtist)
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.dim)
                    .lineLimit(1)
            }

            Spacer()

            // Playing indicator
            if isPlaying {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(RetroPalette.green)
                            .frame(width: 3, height: CGFloat.random(in: 6...16))
                            .animation(
                                .easeInOut(duration: 0.4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                                value: isPlaying
                            )
                    }
                }
                .frame(width: 16, height: 16)
            }
        }
        .padding(8)
        .background(RetroPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(RetroPalette.green.opacity(0.35), lineWidth: 1)
        )
    }
}
