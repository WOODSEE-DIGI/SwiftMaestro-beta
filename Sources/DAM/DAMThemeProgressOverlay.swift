import SwiftUI

// MARK: - Theme-aware progress overlay
//
// Reusable version of the Storage Map scan progress card. Uses the current
// theme accent color for filled blocks and adapts to light/dark appearances.
// Supports both determinate progress (fraction + count/ETA text) and
// indeterminate "scanning" animation.

struct DAMThemeProgressOverlay: View {
    let message: String
    /// Determinate fill fraction (0…1). nil renders the indeterminate bar.
    let fraction: Double?
    /// Primary count text, e.g. "5 / 100".
    let countText: String?
    /// Primary ETA text, e.g. "ETA 2m 30s".
    let etaText: String?
    /// Elapsed seconds to display. nil hides the elapsed line.
    let elapsedSeconds: Double?
    /// Current item/path displayed below the bars.
    let currentItem: String?
    /// Optional secondary bar fraction (0…1), e.g. folders/items.
    let secondaryFraction: Double?
    /// Secondary count text.
    let secondaryCountText: String?
    /// Secondary ETA text.
    let secondaryEtaText: String?

    @Environment(ThemeStore.self) private var theme

    private let blockCount = 48
    private var blockSize: CGFloat { 8 }
    private var barWidth: CGFloat { CGFloat(blockCount) * (blockSize + 2) - 2 }

    var body: some View {
        VStack(spacing: 14) {
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: barWidth)

            if let fraction {
                blockBar(fraction: fraction)

                HStack(spacing: 4) {
                    Text("\(Int(fraction * 100))%")
                        .frame(minWidth: 36, alignment: .leading)
                    Spacer()
                    if let countText {
                        Text(countText)
                    }
                    Spacer()
                    if let etaText {
                        Text(etaText)
                            .frame(minWidth: 70, alignment: .trailing)
                    }
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: barWidth)

                if let secondaryFraction {
                    blockBar(fraction: secondaryFraction, blockHeight: 10)

                    HStack(spacing: 4) {
                        if let secondaryCountText {
                            Text(secondaryCountText)
                        }
                        Spacer()
                        if let secondaryEtaText {
                            Text(secondaryEtaText)
                        }
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .frame(width: barWidth)
                }

                if let currentItem, !currentItem.isEmpty {
                    Text(currentItem)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: barWidth)
                }

                if let elapsedSeconds {
                    Text("Elapsed \(formatDuration(elapsedSeconds))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.8))
                }
            } else {
                DAMThemeIndeterminateBar(message: message, elapsedSeconds: elapsedSeconds)
            }
        }
        .padding(24)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func blockBar(fraction: Double, blockHeight: CGFloat = 20) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<blockCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Double(index) < Double(blockCount) * fraction
                          ? theme.accent
                          : Color.primary.opacity(0.12))
                    .frame(width: blockSize, height: blockHeight)
            }
        }
        .frame(width: barWidth, alignment: .leading)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let secs = total % 60
        if minutes < 60 { return "\(minutes)m \(secs)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(mins)m"
    }
}

// MARK: - Indeterminate theme bar

/// Long retro block bar for indeterminate scans. Uses the current theme accent
/// color and shows elapsed time.
struct DAMThemeIndeterminateBar: View {
    let message: String
    let elapsedSeconds: Double?

    @Environment(ThemeStore.self) private var theme

    @State private var tick = 0
    private let blockCount = 48
    private let timer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(0..<blockCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(for: index))
                        .frame(width: 8, height: 16)
                }
            }

            if let elapsedSeconds, elapsedSeconds > 0 {
                Text(formatDuration(elapsedSeconds))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: CGFloat(blockCount) * 10 - 2)
        .onReceive(timer) { _ in
            tick = (tick + 1) % (blockCount * 2)
        }
    }

    private func color(for index: Int) -> Color {
        let width = 10
        let head = tick % (blockCount + width)
        let distance = abs(index - head)

        if distance == 0 {
            return theme.accent
        } else if distance <= 2 {
            return theme.accent.opacity(0.85)
        } else if distance <= width {
            return theme.accent.opacity(Double(width - distance) / Double(width) * 0.65 + 0.15)
        } else {
            return Color.primary.opacity(0.12)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s elapsed" }
        let minutes = total / 60
        let secs = total % 60
        return "\(minutes)m \(secs)s elapsed"
    }
}

#Preview {
    VStack(spacing: 20) {
        DAMThemeProgressOverlay(
            message: "Scanning System…",
            fraction: 0.35,
            countText: "18.21 GB / 3.88 TB",
            etaText: "ETA 8m 1s",
            elapsedSeconds: 3,
            currentItem: nil,
            secondaryFraction: 0.8,
            secondaryCountText: "Folders: 16 / 20",
            secondaryEtaText: "ETA 1s"
        )
        .environment(ThemeStore())

        DAMThemeProgressOverlay(
            message: "Loading catalog…",
            fraction: nil,
            countText: nil,
            etaText: nil,
            elapsedSeconds: 12,
            currentItem: nil,
            secondaryFraction: nil,
            secondaryCountText: nil,
            secondaryEtaText: nil
        )
        .environment(ThemeStore())
    }
    .padding()
}
