import SwiftUI
import AppKit

/// Storage Health panel for MaestroDAM.
///
/// Lists every cataloged volume, shows capacity/health bars, SMART status,
/// temperature, power-on hours, and warns when a drive should be replaced.
struct DAMVolumeHealthView: View {
    @State private var volumes: [DAMVolume] = []
    @State private var isScanning = false
    @State private var metricStore = DAMHealthMetricsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(volumes) { volume in
                VolumeHealthRow(volume: volume)
            }
            .listStyle(.inset)
            .overlay {
                if isScanning && volumes.isEmpty {
                    VStack(spacing: 8) {
                        RetroScanIndicator(message: "Scanning storage health…")
                        Text("Checking volumes and SMART status…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .task { await loadVolumes() }
    }

    private var header: some View {
        HStack {
            Text("Storage Health")
                .font(.title3.weight(.semibold))
            Spacer()
            if isScanning {
                RetroScanIndicator(message: "Scanning drives…")
            }
            metricsMenu
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning)
        }
        .padding()
    }

    private var metricsMenu: some View {
        let categories = Dictionary(grouping: DAMHealthMetric.allCases, by: \.category)
        return Menu {
            ForEach(categories.keys.sorted(), id: \.self) { category in
                Section(category) {
                    let metrics = categories[category]?
                        .sorted(by: { $0.displayName < $1.displayName }) ?? []
                    ForEach(metrics) { metric in
                        Toggle(metric.displayName, isOn: metricBinding(for: metric))
                    }
                }
            }
            Divider()
            Button("Reset to defaults") {
                metricStore.resetToDefaults()
            }
        } label: {
            Label("Metrics", systemImage: "line.3.horizontal.decrease.circle")
        }
    }

    private func metricBinding(for metric: DAMHealthMetric) -> Binding<Bool> {
        Binding(
            get: { metricStore.isSelected(metric) },
            set: { _ in metricStore.toggle(metric) }
        )
    }

    private func loadVolumes() async {
        isScanning = true
        defer { isScanning = false }
        let refreshed = await DAMVolumeStore.shared.refreshOnlineState(runHealthScan: false)
        volumes = refreshed.filter { isDisplayableVolume($0) }
    }

    private func refresh() async {
        isScanning = true
        defer { isScanning = false }
        let refreshed = await DAMVolumeStore.shared.refreshOnlineState(runHealthScan: true)
        volumes = refreshed.filter { isDisplayableVolume($0) }
        // Pull the latest persisted health rows (refreshOnlineState returns
        // pre-health volumes; re-fetch to show JSON snapshots).
        if let rows: [DAMVolume] = try? await DAMDatabase.shared.dbQueue.read({ db in
            try DAMVolume.order(DAMVolume.Columns.name).fetchAll(db)
        }) {
            volumes = rows.filter { isDisplayableVolume($0) }
        }
    }

    private func isDisplayableVolume(_ volume: DAMVolume) -> Bool {
        guard !DAMVolumeStore.isSnapshotName(volume.name) else { return false }
        let url = URL(fileURLWithPath: "/Volumes/\(volume.name)")
        return !DAMVolumeStore.isSystemOrSyntheticName(volume.name, url: url)
    }
}

// MARK: - Row

private struct VolumeHealthRow: View {
    let volume: DAMVolume
    @State private var metricStore = DAMHealthMetricsStore.shared
    @State private var showingFaults = false

    private var health: StorageHealth? {
        guard let json = volume.healthJSON,
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StorageHealth.self, from: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(statusColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.headline)
                    if volume.healthWarnReplace {
                        Label("Replace recommended", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    } else if volume.isOnline {
                        Text("Online")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Offline")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let score = health?.score {
                    HealthScoreBadge(score: score)
                }
            }

            if volume.isOnline, let capacity = volume.capacityBytes, capacity > 0 {
                CapacityBar(usedBytes: capacity - (volume.freeBytes ?? 0), totalBytes: capacity)
            }

            if let health {
                let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(DAMHealthMetric.allCases.filter { metricStore.isSelected($0) }) { metric in
                        metricPill(for: metric, health: health)
                    }
                }

                if let message = health.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let faults = health.faults
                if !faults.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showingFaults.toggle()
                        }
                    } label: {
                        Label(
                            showingFaults
                                ? "Hide details"
                                : "Show \(faults.count) issue\(faults.count == 1 ? "" : "s")",
                            systemImage: showingFaults ? "chevron.up" : "chevron.down"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                    if showingFaults {
                        FaultsSection(faults: faults, volumeName: volume.name)
                    }
                }
            } else {
                Text(volume.isOnline ? "No health snapshot yet. Click Refresh." : "Drive is offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func metricPill(for metric: DAMHealthMetric, health: StorageHealth) -> some View {
        if let (label, value, color) = metricValue(metric: metric, health: health) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
        }
    }

    private func metricValue(
        metric: DAMHealthMetric,
        health: StorageHealth
    ) -> (label: String, value: String, color: Color)? {
        switch metric {
        case .smartStatus:
            guard let v = health.smartStatus else { return nil }
            let color: Color = health.status == .failing ? .red : (health.status == .caution ? .yellow : .green)
            return (metric.displayName, v, color)
        case .healthScore:
            let score = health.score
            let color: Color = score >= 80 ? .green : (score >= 50 ? .yellow : .red)
            return (metric.displayName, "\(score)", color)
        case .freeSpace:
            guard let v = health.freeSpacePercent else { return nil }
            let color: Color = v < 10 ? .red : (v < 20 ? .yellow : .green)
            return (metric.displayName, "\(v)%", color)
        case .filesystemVerify:
            guard let ok = health.filesystemVerifyOK else { return nil }
            return (metric.displayName, ok ? "Verified" : "Failed", ok ? .green : .red)
        case .temperature:
            guard let v = health.temperatureC else { return nil }
            let color: Color = v > 70 ? .red : (v > 55 ? .yellow : .green)
            return (metric.displayName, "\(v)°C", color)
        case .powerOnHours:
            guard let v = health.powerOnHours else { return nil }
            return (metric.displayName, formatHours(v), .secondary)
        case .powerCycles, .startStops, .loadCycles, .udmaCRCErrors,
             .reallocatedSectors, .pendingSectors, .offlineUncorrectable,
             .gSenseErrors, .multiZoneErrors:
            guard let v = countFor(metric, health) else { return nil }
            let isErrorMetric: Bool = {
                switch metric {
                case .udmaCRCErrors, .offlineUncorrectable, .reallocatedSectors,
                     .pendingSectors, .gSenseErrors, .multiZoneErrors:
                    return true
                default:
                    return false
                }
            }()
            let color: Color = (isErrorMetric && v > 0) ? .red : .secondary
            return (metric.displayName, "\(v)", color)
        case .wearLevel:
            guard let v = health.wearLevelPercent else { return nil }
            let color: Color = v > 90 ? .red : (v > 80 ? .yellow : .green)
            return (metric.displayName, "\(v)%", color)
        case .percentageUsed:
            guard let v = health.percentageUsed else { return nil }
            let color: Color = v > 90 ? .red : (v > 80 ? .yellow : .green)
            return (metric.displayName, "\(v)%", color)
        case .fileVault:
            guard let v = health.fileVaultEnabled else { return nil }
            return (metric.displayName, v ? "On" : "Off", v ? .green : .secondary)
        case .encryption:
            guard let v = health.encryptionEnabled else { return nil }
            return (metric.displayName, v ? "On" : "Off", v ? .green : .secondary)
        case .timeMachineBackup:
            guard let d = health.timeMachineLastBackup else { return nil }
            let formatter = RelativeDateTimeFormatter()
            return (metric.displayName, formatter.localizedString(for: d, relativeTo: Date()), .secondary)
        case .busProtocol:
            guard let v = health.busProtocol else { return nil }
            return (metric.displayName, v, .secondary)
        case .isSSD:
            guard let v = health.isSSD else { return nil }
            return (metric.displayName, v ? "SSD" : "HDD", .secondary)
        }
    }

    private func countFor(_ metric: DAMHealthMetric, _ health: StorageHealth) -> Int? {
        switch metric {
        case .powerCycles:        return health.powerCycleCount
        case .startStops:         return health.startStopCount
        case .loadCycles:         return health.loadCycleCount
        case .udmaCRCErrors:      return health.udmaCRCErrorCount
        case .reallocatedSectors: return health.reallocatedSectorCount
        case .pendingSectors:     return health.pendingSectorCount
        case .offlineUncorrectable: return health.offlineUncorrectable
        case .gSenseErrors:       return health.gSenseErrorRate
        case .multiZoneErrors:    return health.multiZoneErrorCount
        default:                  return nil
        }
    }

    private var iconName: String {
        switch health?.status {
        case .healthy: return "externaldrive.fill.badge.checkmark"
        case .caution: return "externaldrive.fill.badge.exclamationmark"
        case .failing: return "externaldrive.fill.badge.xmark"
        case .unsupported, .unknown, .none: return "externaldrive.fill"
        }
    }

    private var statusColor: Color {
        switch health?.status {
        case .healthy: return .green
        case .caution: return .yellow
        case .failing: return .red
        case .unsupported, .unknown, .none: return .secondary
        }
    }

    private func formatHours(_ hours: Int) -> String {
        let days = hours / 24
        if days >= 365 {
            return String(format: "%.1f years", Double(days) / 365.0)
        } else if days >= 30 {
            return String(format: "%.1f months", Double(days) / 30.0)
        } else {
            return "\(days) days"
        }
    }
}

// MARK: - Subviews

private struct HealthScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.system(.title3, design: .rounded).weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(scoreColor, in: Circle())
    }

    private var scoreColor: Color {
        switch score {
        case 80...100: return .green
        case 50..<80: return .yellow
        default: return .red
        }
    }
}

private struct CapacityBar: View {
    let usedBytes: Int64
    let totalBytes: Int64

    private var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(fraction > 0.9 ? Color.red : Color.accentColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
            HStack {
                Text("Used: \(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))")
                Spacer()
                Text("Total: \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Faults detail

private struct FaultsSection: View {
    let faults: [StorageHealthFault]
    let volumeName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(faults) { fault in
                FaultRow(fault: fault)
            }

            HStack(spacing: 12) {
                Button {
                    openDiskUtility()
                } label: {
                    Label("Open Disk Utility", systemImage: "stethoscope")
                }

                Button {
                    openTimeMachine()
                } label: {
                    Label("Back Up Now", systemImage: "clock.arrow.2.circlepath")
                }
            }
            .font(.caption)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.red.opacity(0.25))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func openDiskUtility() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"),
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }

    private func openTimeMachine() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct FaultRow: View {
    let fault: StorageHealthFault

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(severityColor)
                .font(.caption.weight(.semibold))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(fault.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(fault.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Action: \(fault.action)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(severityColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var iconName: String {
        switch fault.severity {
        case .critical: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var severityColor: Color {
        switch fault.severity {
        case .critical: return .red
        case .warning: return .yellow
        case .info: return .secondary
        }
    }
}


