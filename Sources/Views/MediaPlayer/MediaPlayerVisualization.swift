import SwiftUI

// MARK: - Media Player Visualization
//
// Real-time spectrum analyzer display tied to playback audio.
// Extends the existing RetroSpectrumMeter with playback-aware state.

struct MediaPlayerVisualization: View {
    let spectrum: [Float]
    let caps: [Float]?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SPECTRUM")
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.green.opacity(0.6))
                Spacer()
                Text("24 BAND")
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.green.opacity(0.4))
            }

            RetroSpectrumMeter(spectrum: spectrum, cellsPerBar: 10, caps: caps)
        }
    }
}

// MARK: - Waveform View

/// Simple waveform display showing recent amplitude history.
struct MediaPlayerWaveformView: View {
    let samples: [Float]
    let barColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("WAVEFORM")
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.green.opacity(0.6))
                Spacer()
            }

            GeometryReader { geo in
                let barWidth = max(1, (geo.size.width - CGFloat(max(samples.count - 1, 0))) / CGFloat(max(samples.count, 1)))

                HStack(alignment: .center, spacing: 1) {
                    ForEach(0..<samples.count, id: \.self) { i in
                        let sample = samples[i]
                        let barHeight = max(2, CGFloat(abs(sample)) * geo.size.height * 0.8)

                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(barColor.opacity(0.6 + 0.4 * Double(abs(sample))))
                            .frame(width: barWidth, height: barHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
