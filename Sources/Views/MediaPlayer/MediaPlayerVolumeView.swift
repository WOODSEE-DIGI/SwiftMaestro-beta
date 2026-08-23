import SwiftUI

// MARK: - Media Player Volume View
//
// Retro segmented volume slider with mute toggle and dB readout.
// Horizontal layout to fit the transport bar.

struct MediaPlayerVolumeView: View {
    @Binding var volume: Double
    @Binding var isMuted: Bool
    let segments: Int = 20

    var body: some View {
        HStack(spacing: 6) {
            // Mute toggle
            Button {
                isMuted.toggle()
            } label: {
                Image(systemName: isMuted ? "speaker.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(isMuted ? RetroPalette.red : RetroPalette.green.opacity(0.8))
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            // Segmented bar
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    let fraction = Double(i + 1) / Double(segments)
                    let filled = !isMuted && Double(volume) * Double(segments) >= Double(i + 1)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(filled ? volumeColor(fraction: fraction) : RetroPalette.dim)
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Double(min(1, max(0, value.location.x / (20.0 * Double(segments)))))
                        volume = fraction
                        isMuted = false
                    }
            )

            // dB readout
            Text(dbText)
                .font(.caption2.monospaced())
                .foregroundStyle(RetroPalette.green.opacity(0.7))
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RetroPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(RetroPalette.green.opacity(0.25), lineWidth: 1)
        )
    }

    private func volumeColor(fraction: Double) -> Color {
        switch fraction {
        case ..<0.6:  return RetroPalette.green
        case ..<0.85: return RetroPalette.amber
        default:      return RetroPalette.red
        }
    }

    private var dbText: String {
        let effectiveVolume = isMuted ? 0.0 : volume
        let db = effectiveVolume > 0.0001 ? 20 * log10(effectiveVolume) : -60
        return String(format: "%5.1f dB", max(-60, db))
    }
}
