import SwiftUI

// MARK: - Media Player Progress Bar
//
// Segmented horizontal progress bar with position marker, time readout,
// and scrub-on-click. Uses the RetroPalette from RetroAudioViews for
// visual consistency.

struct MediaPlayerProgressBar: View {
    let currentTime: Double
    let duration: Double
    let isSeeking: Bool
    let onSeek: (Double) -> Void

    private let segmentCount = 60
    private let barHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 4) {
            // Segmented bar
            GeometryReader { geo in
                let progress = duration > 0 ? currentTime / duration : 0

                ZStack(alignment: .leading) {
                    // Background segments
                    HStack(spacing: 2) {
                        ForEach(0..<segmentCount, id: \.self) { i in
                            let segProgress = Double(i + 1) / Double(segmentCount)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(segProgress <= progress
                                      ? segmentColor(fraction: segProgress)
                                      : RetroPalette.dim)
                                .frame(maxWidth: .infinity)
                                .frame(height: barHeight)
                        }
                    }

                    // Position marker (bright white line)
                    if duration > 0 {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: barHeight)
                            .offset(x: max(0, geo.size.width * CGFloat(progress) - 1))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let fraction = Double(location.x / geo.size.width)
                    let seekTime = fraction * duration
                    onSeek(max(0, min(seekTime, duration)))
                }
            }
            .frame(height: barHeight)

            // Time readout
            HStack {
                Text(formatTime(currentTime))
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.green.opacity(0.9))
                Spacer()
                if isSeeking {
                    Text("SEEK")
                        .font(.caption2.monospaced())
                        .foregroundStyle(RetroPalette.amber)
                }
                Text(formatTime(duration))
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.green.opacity(0.6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RetroPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(RetroPalette.green.opacity(0.35), lineWidth: 1)
        )
    }

    private func segmentColor(fraction: Double) -> Color {
        switch fraction {
        case ..<0.55: return RetroPalette.green
        case ..<0.8:  return RetroPalette.amber
        default:      return RetroPalette.red
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
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
