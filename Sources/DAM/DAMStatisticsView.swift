import SwiftUI
import Charts

/// Statistics dashboard for the MaestroDAM Home workspace.
///
/// Shows KPI cards, file-type pie/column charts, flag/rating/volume
/// distributions, and top-heavy folders. The scope toggle switches between
/// the entire catalog and the currently selected folder.
struct DAMStatisticsView: View {
    var viewModel: DAMViewModel

    @State private var stats: DAMCatalogStats?
    @State private var isLoading = false
    @State private var scope: Scope = .entireCatalog

    @AppStorage("dam.stats.showKPI") private var showKPI = true
    @AppStorage("dam.stats.showFileTypes") private var showFileTypes = true
    @AppStorage("dam.stats.showStorageHealth") private var showStorageHealth = true
    @AppStorage("dam.stats.showFlags") private var showFlags = true
    @AppStorage("dam.stats.showRatings") private var showRatings = true
    @AppStorage("dam.stats.showColorTags") private var showColorTags = true
    @AppStorage("dam.stats.showVolumes") private var showVolumes = true
    @AppStorage("dam.stats.showTopFolders") private var showTopFolders = true

    enum Scope: String, CaseIterable {
        case entireCatalog = "Entire catalog"
        case selectedFolder = "Selected folder"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                if scope == .selectedFolder, let folder = viewModel.selectedFolder {
                    Text(folder)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isLoading {
                    RetroScanIndicator(message: "Scanning catalog…")
                }

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)

                Menu {
                    Toggle("KPI cards", isOn: $showKPI)
                    Toggle("File types", isOn: $showFileTypes)
                    Toggle("Storage health", isOn: $showStorageHealth)
                    Toggle("Flags", isOn: $showFlags)
                    Toggle("Ratings", isOn: $showRatings)
                    Toggle("Color tags", isOn: $showColorTags)
                    Toggle("Volumes", isOn: $showVolumes)
                    Toggle("Heaviest folders", isOn: $showTopFolders)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .help("Customize sections")
            }
            .padding()

            Divider()

            if let stats {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if showKPI { kpiRow(stats: stats) }
                        if showFileTypes { kindSection(stats: stats) }
                        if showStorageHealth { storageHealthSection }
                        if showFlags || showRatings || showColorTags {
                            HStack(alignment: .top, spacing: 20) {
                                if showFlags { flagSection(stats: stats) }
                                if showRatings { ratingSection(stats: stats) }
                                if showColorTags { colorTagSection(stats: stats) }
                            }
                        }
                        if showVolumes { volumeSection(stats: stats) }
                        if showTopFolders { topFoldersSection(stats: stats) }
                    }
                    .padding()
                }
            } else if isLoading {
                RetroLoadingOverlay(message: "Scanning catalog…")
            } else {
                Spacer()
                ContentUnavailableView("No statistics", systemImage: "chart.bar", description: Text("Select a scope and refresh."))
                Spacer()
            }
        }
        .task(id: scope) { await load() }
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let folder = (scope == .selectedFolder) ? viewModel.selectedFolder : nil
        stats = await DAMStatisticsService.shared.stats(forFolderPath: folder)
    }

    // MARK: - KPI

    private func kpiRow(stats: DAMCatalogStats) -> some View {
        let mediaKinds = Set(["movie", "audio"])
        let mediaCount = stats.byKind.filter { mediaKinds.contains($0.kind) }.map(\.count).reduce(0, +)
        let hasRealDuration = stats.totalDuration >= 1
        let durationValue: String = {
            guard hasRealDuration else {
                return mediaCount > 0 ? "Calculating…" : "—"
            }
            return formatDuration(stats.totalDuration)
        }()
        return HStack(spacing: 16) {
            KPICard(title: "Files", value: "\(stats.totalAssets.formatted())", icon: "doc.on.doc")
            KPICard(title: "Size", value: formatBytes(stats.totalSize), icon: "externaldrive")
            KPICard(title: "Duration", value: durationValue, icon: "film")
            KPICard(title: "Offline", value: "\(stats.offlineAssets.formatted())", icon: "externaldrive.badge.xmark", accent: .orange)
        }
    }

    // MARK: - Storage health

    private var storageHealthSection: some View {
        DAMVolumeHealthView()
            .frame(minHeight: 180)
            .padding()
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - File type breakdown

    private func kindSection(stats: DAMCatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("File types")
                .font(.headline)

            HStack(alignment: .top, spacing: 24) {
                // Pie
                Chart(stats.byKind) { item in
                    SectorMark(
                        angle: .value("Size", item.size),
                        innerRadius: .ratio(0.5),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Kind", kindDisplayName(item.kind)))
                    .cornerRadius(4)
                }
                .frame(height: 220)
                .chartLegend(position: .trailing, alignment: .top, spacing: 16)

                // Column
                VStack(alignment: .leading, spacing: 8) {
                    Text("By size")
                        .font(.subheadline.weight(.semibold))
                    Chart(stats.byKind) { item in
                        BarMark(
                            x: .value("Kind", kindDisplayName(item.kind)),
                            y: .value("Size (TB)", bytesToTB(item.size))
                        )
                        .foregroundStyle(kindColor(item.kind))
                        .cornerRadius(4)
                    }
                    .frame(height: 180)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let tb = value.as(Double.self) {
                                    Text(String(format: "%.1f TB", tb))
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                    .chartXAxis { AxisMarks(position: .bottom) }
                }
                .frame(minWidth: 260)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Flags & ratings

    private func flagSection(stats: DAMCatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Flags")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(stats.byFlag) { item in
                    HStack(spacing: 8) {
                        Image(systemName: flagIcon(item.flag))
                            .foregroundStyle(flagColor(item.flag))
                            .frame(width: 20)
                        Text(flagName(item.flag))
                            .font(.caption)
                            .frame(width: 50, alignment: .leading)
                        BtopBar(value: Double(item.count), max: maxCount(stats.byFlag.map(\.count)), color: flagColor(item.flag))
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func ratingSection(stats: DAMCatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ratings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(stats.byRating) { item in
                    HStack(spacing: 8) {
                        Text(item.rating == 0 ? "None" : String(repeating: "★", count: item.rating))
                            .font(.caption)
                            .frame(width: 50, alignment: .leading)
                        BtopBar(value: Double(item.count), max: maxCount(stats.byRating.map(\.count)), color: .yellow)
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func colorTagSection(stats: DAMCatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color tags")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(stats.byColorTag) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(tagColor(item.colorIndex))
                            .frame(width: 10, height: 10)
                        Text(item.name)
                            .font(.caption)
                            .frame(width: 50, alignment: .leading)
                        BtopBar(value: Double(item.count), max: maxCount(stats.byColorTag.map(\.count)), color: tagColor(item.colorIndex))
                        Text("\(item.count)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tagColor(_ index: Int) -> Color {
        switch index {
        case 1: return .gray
        case 2: return .green
        case 3: return .purple
        case 4: return .blue
        case 5: return .yellow
        case 6: return .red
        case 7: return .orange
        default: return .secondary
        }
    }

    // MARK: - Volumes

    private func volumeSection(stats: DAMCatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volumes")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(stats.byVolume) { vol in
                    HStack(spacing: 10) {
                        Image(systemName: vol.isOnline ? "externaldrive.fill" : "externaldrive.fill.badge.xmark")
                            .foregroundStyle(vol.warnReplace ? .red : (vol.isOnline ? .green : .secondary))
                        Text(vol.name)
                            .font(.caption.weight(.medium))
                            .frame(width: 120, alignment: .leading)
                        BtopBar(value: Double(vol.size), max: Double(stats.byVolume.map(\.size).max() ?? 1), color: vol.warnReplace ? .red : .accentColor)
                        Text(formatBytes(vol.size))
                            .font(.caption.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Top folders

    private func topFoldersSection(stats: DAMCatalogStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Heaviest folders")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(stats.topFolders.prefix(10)) { folder in
                    HStack(spacing: 10) {
                        Text((folder.path as NSString).lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 200, alignment: .leading)
                        BtopBar(value: Double(folder.size), max: Double(stats.topFolders.first?.size ?? 1), color: .cyan)
                        Text("\(folder.count)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 50, alignment: .trailing)
                        Text(formatBytes(folder.size))
                            .font(.caption.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func kindDisplayName(_ kind: String) -> String {
        switch kind {
        case "image": return "Image"
        case "raw": return "RAW"
        case "movie": return "Video"
        case "audio": return "Audio"
        case "pdf": return "PDF"
        case "document": return "Document"
        default: return "Other"
        }
    }

    private func kindColor(_ kind: String) -> Color {
        switch kind {
        case "image": return .blue
        case "raw": return .indigo
        case "movie": return .red
        case "audio": return .purple
        case "pdf": return .orange
        case "document": return .green
        default: return .gray
        }
    }

    private func flagIcon(_ flag: DAMFlag) -> String {
        switch flag {
        case .none: return "minus.circle"
        case .pick: return "flag.fill"
        case .reject: return "xmark.circle"
        }
    }

    private func flagColor(_ flag: DAMFlag) -> Color {
        switch flag {
        case .none: return .secondary
        case .pick: return .green
        case .reject: return .red
        }
    }

    private func flagName(_ flag: DAMFlag) -> String {
        switch flag {
        case .none: return "None"
        case .pick: return "Pick"
        case .reject: return "Reject"
        }
    }

    private func maxCount(_ values: [Int]) -> Double {
        Double(values.max() ?? 0)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0s"
    }

    private func bytesToTB(_ bytes: Int64) -> Double {
        Double(bytes) / 1_099_511_627_776.0
    }
}

// MARK: - Subviews

private struct KPICard: View {
    let title: String
    let value: String
    let icon: String
    var accent: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(accent)
                Spacer()
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Btop-inspired horizontal segmented bar.
private struct BtopBar: View {
    let value: Double
    let max: Double
    let color: Color

    private var fraction: Double {
        guard max > 0 else { return 0 }
        return min(1, value / max)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.gradient)
                    .frame(width: geo.size.width * fraction)
                    .animation(.easeOut(duration: 0.25), value: fraction)
            }
        }
        .frame(height: 12)
    }
}
