import SwiftUI

// MARK: - Resource status indicator

/// A compact live indicator of how hard the on-device AI/scanner pipelines are
/// pushing the system. Shown in the MaestroDAM status bar.
struct DAMResourceStatusView: View {
    @State private var status = DAMResourceStatus.shared

    var body: some View {
        HStack(spacing: 6) {
            if status.activeHeavyTasks > 0 || status.queuedHeavyTasks > 0 {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)

                Text("\(status.activeHeavyTasks) active")
                    .font(.caption2.monospacedDigit())

                if status.queuedHeavyTasks > 0 {
                    Text("· \(status.queuedHeavyTasks) queued")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = status.lastSnapshot {
                HStack(spacing: 4) {
                    Image(systemName: thermalIcon(for: snapshot.thermalState))
                        .foregroundStyle(thermalColor(for: snapshot.thermalState))
                        .help("Thermal: \(snapshot.thermalState.description)")

                    Text(String(format: "%.1f GB", snapshot.availableMemoryGB))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(memoryColor(availableGB: snapshot.availableMemoryGB))
                        .help("Available memory")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("DAMResourceStatusChanged"))) { _ in
            // Observable auto-updates; this keeps the view responsive when
            // status changes happen off the main actor.
        }
    }

    private func thermalIcon(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal, .fair: return "thermometer.low"
        case .serious: return "thermometer.high"
        case .critical: return "flame.fill"
        @unknown default: return "thermometer.medium"
        }
    }

    private func thermalColor(for state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal, .fair: return .secondary
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    private func memoryColor(availableGB: Double) -> Color {
        if availableGB < 2.0 { return .red }
        if availableGB < 4.0 { return .orange }
        return .secondary
    }
}
