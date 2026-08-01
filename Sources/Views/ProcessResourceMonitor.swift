import SwiftUI

/// Compact process/resource monitor for the sidebar, positioned above the
/// engine status bar. Shows SwiftMaestro's own CPU, memory, generation state,
/// and a warning if the process looks idle while it should be generating.
struct ProcessResourceMonitor: View {
    private let sampler = ProcessResourceSampler.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            metricsRow

            if !sampler.history.isEmpty {
                let accent = sampler.isStuck ? Color.orange : (sampler.isGenerating ? Color.blue : Color.green)
                // Sparkline shows SwiftMaestro process CPU % over the last 60 seconds.
                Sparkline(samples: sampler.history.map(\.cpuPercent))
                    .fill(accent.opacity(0.25))
                    .overlay(
                        Sparkline(samples: sampler.history.map(\.cpuPercent))
                            .stroke(style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(accent)
                    )
                    .frame(height: 24)
            }

            if sampler.isStuck {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("No token activity for 15s — may be stuck")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.orange)
            }

            if !sampler.subagents.isEmpty {
                subagentsSection
            }
        }
        .onAppear {
            ProcessResourceSampler.shared.start()
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("SwiftMaestro")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(sampler.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var metricsRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("CPU usage")
                Text(sampler.current.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "--")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("RAM usage")
                Text(sampler.current.map { formatBytes($0.memoryBytes) } ?? "--")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "number")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Active threads")
                Text("\(sampler.current?.threads ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        if sampler.isStuck { return .orange }
        if sampler.isGenerating { return .blue }
        return .green
    }

    private var subagentsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subagents")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            ForEach(Array(sampler.subagents.values).sorted(by: { $0.name < $1.name })) { status in
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.isGenerating ? Color.blue : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(status.name)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if status.isGenerating, status.tokensPerSecond > 0 {
                        Text(String(format: "%.1f tok/s", status.tokensPerSecond))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if status.isGenerating {
                        Text("Generating…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Idle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        } else {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576)
        }
    }
}

// MARK: - Sparkline

/// Filled area sparkline. The path closes along the bottom so it can be filled
/// and then stroked on top for a thick, visible line.
struct Sparkline: Shape {
    let samples: [Double]
    var maxValue: Double = 200

    func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }
        var path = Path()
        let stepX = rect.width / CGFloat(samples.count - 1)
        let scaleY = rect.height / CGFloat(max(1, maxValue))

        path.move(to: CGPoint(x: 0, y: rect.height))

        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * stepX
            let y = rect.height - CGFloat(min(sample, maxValue)) * scaleY
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()

        return path
    }
}
