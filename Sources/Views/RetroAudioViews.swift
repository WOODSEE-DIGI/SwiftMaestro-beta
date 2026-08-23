import SwiftUI

// MARK: - Retro Audio Views (btop-style)
//
// Phosphor-on-black segmented meters inspired by btop and console VU
// bridges: blocky segment cells, green→amber→red zones, peak-hold caps,
// monospace readouts. Shared by the Audio Control panel (live monitor + EQ
// bank) and the Voice Notes recording UI (compact level bar).

/// Retro palette (deliberate aesthetic — not theme-driven).
enum RetroPalette {
    static let green = Color(red: 0.20, green: 1.00, blue: 0.35)
    static let amber = Color(red: 1.00, green: 0.75, blue: 0.20)
    static let red = Color(red: 1.00, green: 0.30, blue: 0.25)
    static let dim = Color(red: 0.10, green: 0.16, blue: 0.10)
    static let background = Color(white: 0.055)

    /// Segment color by vertical position (0 = bottom).
    static func zone(fraction: Double) -> Color {
        switch fraction {
        case ..<0.55: return green
        case ..<0.8: return amber
        default: return red
        }
    }
}

// MARK: - Spectrum meter

/// 24-band spectrum analyzer: each band is a column of segment cells filled
/// bottom-up, with a slow-falling peak cap cell on top. Log-spaced lows →
/// highs left → right.
struct RetroSpectrumMeter: View {
    let spectrum: [Float]          // 0…1 per band
    var cellsPerBar: Int = 12

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<spectrum.count, id: \.self) { band in
                RetroBarColumn(value: spectrum[band], cells: cellsPerBar)
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

/// One bar column: bottom-up filled segments, zone-colored by height.
private struct RetroBarColumn: View {
    let value: Float
    let cells: Int

    var body: some View {
        VStack(spacing: 2) {
            ForEach((0..<cells).reversed(), id: \.self) { row in
                let fraction = Double(row + 1) / Double(cells)
                let filled = Double(value) * Double(cells) >= Double(row + 1)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(filled ? RetroPalette.zone(fraction: fraction) : RetroPalette.dim)
                    .frame(maxWidth: .infinity)
                    .frame(height: 7)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Level meter

/// Horizontal segmented VU bar with peak-hold marker and a dB readout.
struct RetroLevelMeter: View {
    let level: Float      // 0…1 RMS
    let peak: Float       // 0…1 peak-hold
    var segments: Int = 40
    var label: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { seg in
                    let fraction = Double(seg + 1) / Double(segments)
                    let filled = Double(level) * Double(segments) >= Double(seg + 1)
                    let isPeak = abs(Double(peak) * Double(segments) - Double(seg + 1)) < 0.5
                        && peak > 0.02
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isPeak ? Color.white
                              : filled ? RetroPalette.zone(fraction: fraction)
                              : RetroPalette.dim)
                        .frame(height: 14)
                }
            }
            HStack {
                if let label {
                    Text(label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(RetroPalette.green.opacity(0.8))
                }
                Spacer()
                Text(dbText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(RetroPalette.green.opacity(0.8))
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

    private var dbText: String {
        let db = level > 0.0001 ? 20 * log10(Double(level)) : -60
        return String(format: "%6.1f dB", max(-60, db))
    }
}

// MARK: - EQ bank

/// The 8-band retro EQ: vertical segment sliders with dB thumbs, preset row,
/// bypass. Edits AudioEQSettings.shared (persisted; applied to the Voice
/// Notes recording chain).
struct RetroEQBank: View {
    @State private var eq = AudioEQSettings.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                ForEach(0..<AudioEQSettings.bandFrequencies.count, id: \.self) { band in
                    RetroEQSlider(
                        frequency: AudioEQSettings.bandFrequencies[band],
                        gain: Binding(
                            get: { eq.gains[band] },
                            set: { eq.gains[band] = min(12, max(-12, $0)) }
                        ),
                        disabled: eq.isBypassed
                    )
                }
            }

            HStack {
                Toggle("Bypass EQ", isOn: Binding(
                    get: { eq.isBypassed },
                    set: { eq.isBypassed = $0 }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Spacer()

                Menu("Preset") {
                    ForEach(AudioEQSettings.Preset.allCases, id: \.self) { preset in
                        Button(preset.rawValue) { eq.apply(preset) }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

/// One band: a vertical column of segments with a bright thumb that drags.
private struct RetroEQSlider: View {
    let frequency: Float
    @Binding var gain: Float   // −12…+12 dB
    let disabled: Bool

    private let cells = 17     // segment count (odd = center detent at 0 dB)

    var body: some View {
        VStack(spacing: 3) {
            Text(String(format: "%+.0f", gain))
                .font(.caption2.monospaced())
                .foregroundStyle(RetroPalette.green)
                .frame(height: 12)

            // The slider column: thumb position by gain (top = +12 dB).
            VStack(spacing: 2) {
                ForEach((0..<cells).reversed(), id: \.self) { row in
                    let rowDB = Double(cells - 1 - row) / Double(cells - 1) * 24 - 12
                    let isThumb = abs(Double(gain) - rowDB) < (12.0 / Double(cells - 1))
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(isThumb ? Color.white : segmentColor(rowDB: rowDB))
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 26, height: 170)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !disabled else { return }
                        // Map drag Y within the column height to ±12 dB.
                        let fraction = 1 - min(1, max(0, value.location.y / 170))
                        gain = Float(fraction * 24 - 12)
                    }
            )
            .disabled(disabled)
            .opacity(disabled ? 0.45 : 1)

            Text(freqLabel)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func segmentColor(rowDB: Double) -> Color {
        // Fill toward center detent: segments between 0 dB and the thumb glow.
        let filled = (gain >= 0 && rowDB >= 0 && rowDB <= Double(gain))
            || (gain < 0 && rowDB <= 0 && rowDB >= Double(gain))
        guard filled else { return RetroPalette.dim }
        switch abs(rowDB) {
        case ..<4: return RetroPalette.green
        case ..<8: return RetroPalette.amber
        default: return RetroPalette.red
        }
    }

    private var freqLabel: String {
        frequency >= 1000
            ? String(format: "%gk", Double(frequency) / 1000.0)   // %g trims: "2.4k"
            : String(format: "%g", Double(frequency))
    }
}
