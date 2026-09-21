import SwiftUI
import AppKit

/// Fresh-scan storage map for the MaestroDAM Home workspace.
///
/// Walks the selected folder (or a chosen volume) and shows a btop-style
/// ranked list of folders by size. Tap a row to drill in; use the breadcrumb
/// to back out.
struct DAMStorageMapView: View {
    var viewModel: DAMViewModel

    @State private var root: StorageMapNode?
    @State private var current: StorageMapNode?
    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanProgress: ScanProgress?
    @State private var scanStartDate: Date?
    @State private var viewMode: ViewMode = .list
    @State private var showingCleanupList = false
    @State private var rescanningPath: String?

    private enum ViewMode: String, CaseIterable {
        case list, chart
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let current {
                if viewMode == .chart {
                    StorageMapSunburstChart(
                        node: current,
                        viewModel: viewModel,
                        rescanningPath: rescanningPath,
                        onSelect: { selected in
                            Task { await drill(into: selected) }
                        },
                        onCenterTap: {
                            if let parent = parentOf(current, in: root), parent.path != current.path {
                                withAnimation { self.current = parent }
                            }
                        }
                    )
                } else {
                    List(current.children) { child in
                        FolderSizeRow(node: child, maxSize: maxSize(in: current), viewModel: viewModel)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await drill(into: child, preferList: true) }
                            }
                            .opacity(rescanningPath == child.path ? 0.5 : 1.0)
                    }
                    .listStyle(.inset)
                }
            } else if isScanning, let scanProgress {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let elapsed = scanStartDate.map { context.date.timeIntervalSince($0) }
                    let message = scanProgress.message
                        ?? (scanProgress.currentPath.map { "Scanning \(($0 as NSString).lastPathComponent)…" }
                            ?? "Scanning…")
                    DAMThemeProgressOverlay(
                        message: message,
                        fraction: scanProgress.totalBytes > 0 ? scanProgress.fraction : nil,
                        countText: scanProgress.totalBytes > 0
                            ? "\(formatBytes(scanProgress.scannedBytes)) / \(formatBytes(scanProgress.totalBytes))"
                            : nil,
                        etaText: scanProgress.totalBytes > 0
                            ? (scanProgress.estimatedSecondsRemaining.map { "ETA \(formatDuration($0))" })
                            : nil,
                        elapsedSeconds: elapsed,
                        currentItem: scanProgress.currentPath,
                        secondaryFraction: scanProgress.totalItems > 0 ? scanProgress.itemFraction : nil,
                        secondaryCountText: scanProgress.totalItems > 0
                            ? "Folders: \(scanProgress.completedItems) / \(scanProgress.totalItems)"
                            : nil,
                        secondaryEtaText: nil
                    )
                }
            } else if let errorMessage {
                Spacer()
                ContentUnavailableView("Scan failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                Spacer()
            } else {
                Spacer()
                ContentUnavailableView("No scan", systemImage: "chart.bar", description: Text("Choose a folder and scan."))
                Spacer()
            }
        }
        .sheet(isPresented: $showingCleanupList) {
            DAMCleanupListSheet()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Storage Map")
                    .font(.title3.weight(.semibold))

                if let current {
                    let crumbs = breadcrumb(for: current)
                    HStack(spacing: 4) {
                        Button { withAnimation { self.current = root } } label: {
                            Image(systemName: "house")
                        }
                        .buttonStyle(.plain)
                        .disabled(root == nil)

                        Button(action: { withAnimation { goBack() } }) {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .disabled(crumbs.count <= 1)

                        if crumbs.count > 1 {
                            ForEach(Array(crumbs.enumerated()), id: \.element.path) { index, node in
                                if index > 0 {
                                    Text("›")
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    withAnimation { self.current = node }
                                } label: {
                                    Text(node.path == "/" ? "Macintosh HD" : node.name)
                                        .font(.caption.weight(node.path == current.path ? .semibold : .medium))
                                        .lineLimit(1)
                                }
                                .buttonStyle(.plain)
                                .disabled(node.path == current.path)
                            }
                        } else {
                            Text("›")
                                .foregroundStyle(.secondary)
                            Text(current.path == "/" ? "Macintosh HD" : current.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                }

                Spacer()

                if let current, !current.children.isEmpty {
                    Picker("View", selection: $viewMode) {
                        Text("List").tag(ViewMode.list)
                        Text("Chart").tag(ViewMode.chart)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .labelsHidden()
                }

                Button {
                    showingCleanupList = true
                } label: {
                    Label("Cleanup", systemImage: "trash")
                }
                .disabled(DAMCleanupListStore.shared.items.isEmpty)

                if isScanning {
                    Button {
                        scanTask?.cancel()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        Task { await startScan() }
                    } label: {
                        Label("Scan selected folder", systemImage: "play")
                    }
                    .disabled(viewModel.selectedFolder == nil)
                }
            }

            if let current {
                let crumbs = breadcrumb(for: current)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(crumbs.enumerated()), id: \.element.path) { index, node in
                            if index > 0 {
                                Text("/")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                withAnimation { self.current = node }
                            } label: {
                                Text(node.path == "/" ? "Macintosh HD" : node.name)
                                    .font(.caption2.weight(node.path == current.path ? .semibold : .regular))
                                    .foregroundStyle(node.path == current.path ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .disabled(node.path == current.path)
                        }
                    }
                }
                .help(current.path)
            }
        }
        .padding()
    }

    // MARK: - Scanning

    private func startScan() async {
        guard let path = viewModel.selectedFolder else {
            errorMessage = "Select a folder in the Folders tree first."
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = "Folder is offline or no longer exists."
            return
        }

        isScanning = true
        errorMessage = nil
        scanStartDate = Date()
        scanProgress = ScanProgress(
            scannedBytes: 0,
            totalBytes: 0,
            currentPath: path,
            message: "Preparing scan…",
            elapsedSeconds: 0,
            completedItems: 0,
            totalItems: 0
        )
        scanTask = Task {
            let node = await DAMStorageMapService.shared.scan(url: url, maxDepth: 6) { @MainActor progress in
                scanProgress = progress
            }
            if !Task.isCancelled {
                self.root = node
                self.current = node
            }
            self.isScanning = false
            self.scanProgress = nil
            self.scanStartDate = nil
        }
    }

    private func maxSize(in node: StorageMapNode) -> Double {
        Double(node.children.map(\.size).max() ?? 1)
    }

    private func parentOf(_ target: StorageMapNode, in root: StorageMapNode?) -> StorageMapNode? {
        guard let root else { return nil }
        for child in root.children {
            if child.path == target.path { return root }
            if let found = parentOf(target, in: child) { return found }
        }
        return nil
    }

    /// The chain of nodes from `root` down to `current`, used for breadcrumbs.
    private func breadcrumb(for current: StorageMapNode) -> [StorageMapNode] {
        guard let root else { return [current] }
        var chain: [StorageMapNode] = []
        func walk(_ candidate: StorageMapNode) -> Bool {
            if candidate.path == current.path {
                chain.append(candidate)
                return true
            }
            for child in candidate.children {
                if walk(child) {
                    chain.insert(candidate, at: 0)
                    return true
                }
            }
            return false
        }
        if walk(root) { return chain }
        return [current]
    }

    private func goBack() {
        guard let current, let parent = parentOf(current, in: root), parent.path != current.path else { return }
        withAnimation { self.current = parent }
    }

    private func drill(into node: StorageMapNode, preferList: Bool = false) async {
        guard rescanningPath == nil else { return }
        if !node.children.isEmpty {
            await MainActor.run {
                withAnimation { self.current = node }
                if preferList { self.viewMode = .list }
            }
            return
        }

        rescanningPath = node.path
        let scanned = await DAMStorageMapService.shared.scanFolder(
            url: URL(fileURLWithPath: node.path),
            maxDepth: 2
        )
        await MainActor.run {
            if let root = self.root {
                self.root = replaceNode(in: root, at: node.path, with: scanned)
            } else {
                self.root = scanned
            }
            withAnimation { self.current = scanned }
            if preferList { self.viewMode = .list }
            self.rescanningPath = nil
        }
    }

    private func replaceNode(in root: StorageMapNode, at path: String, with newNode: StorageMapNode) -> StorageMapNode {
        var copy = root
        if copy.path == path { return newNode }
        copy.children = copy.children.map { child in
            if child.path == path {
                return newNode
            } else if path.hasPrefix(child.path + "/") {
                return replaceNode(in: child, at: path, with: newNode)
            } else {
                return child
            }
        }
        return copy
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

// MARK: - Row

private struct FolderSizeRow: View {
    let node: StorageMapNode
    let maxSize: Double
    var viewModel: DAMViewModel

    private var fraction: Double {
        guard maxSize > 0 else { return 0 }
        return min(1, Double(node.size) / maxSize)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.children.isEmpty ? "doc" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(node.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(formatBytes(node.size))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.15))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(folderHeat(fraction: fraction))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 14)

                HStack {
                    Text("\(node.children.count) subfolders")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(percentageString)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button {
                viewModel.selectedFolder = node.path
                viewModel.workspace = .home
            } label: {
                Label("Show in MaestroDAM", systemImage: "folder")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
            } label: {
                Label("Show in Finder", systemImage: "arrow.right.circle")
            }

            Button {
                DAMCleanupListStore.shared.add(path: node.path)
            } label: {
                Label("Add to cleanup list", systemImage: "trash")
            }
        }
    }

    private var percentageString: String {
        guard maxSize > 0 else { return "0%" }
        return String(format: "%.1f%%", Double(node.size) / maxSize * 100)
    }

    private func folderHeat(fraction: Double) -> Color {
        if fraction > 0.75 { return .red }
        if fraction > 0.5 { return .orange }
        if fraction > 0.25 { return .yellow }
        return .green
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}



