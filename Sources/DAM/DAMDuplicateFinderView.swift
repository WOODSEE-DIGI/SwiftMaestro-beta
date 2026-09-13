import AppKit
import SwiftUI

// MARK: - Duplicate Finder View

/// Scans the MaestroDAM catalog for duplicates and version sets. Supports
/// exact SHA-256 duplicates, visual near-duplicates via pHash, and filename-
/// based version grouping with user-taught patterns.
struct DAMDuplicateFinderView: View {
    var viewModel: DAMViewModel
    @State private var finderModel = DAMDuplicateFinderViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if finderModel.isScanning {
                scanningOverlay
                Divider()
            }

            if finderModel.errorMessage != nil {
                errorBanner
                Divider()
            }

            if finderModel.mode == .perceptual, finderModel.needsPerceptualHashGeneration {
                generateHashesBanner
                Divider()
            }

            resultsList
        }
        .onAppear {
            // Default to the currently selected folder so a user doesn't
            // accidentally kick off a whole-catalog scan.
            if finderModel.selectedScope == nil {
                finderModel.selectedScope = viewModel.selectedFolder
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $finderModel.mode) {
                ForEach(DAMDuplicateFinderMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            .accessibilityLabel("Duplicate detection mode")

            Picker("Scope", selection: Binding(
                get: { finderModel.selectedScope == nil },
                set: { isEntireCatalog in
                    finderModel.selectedScope = isEntireCatalog ? nil : (finderModel.selectedScope ?? viewModel.selectedFolder)
                }
            )) {
                Text("Entire catalog").tag(true)
                Text("Selected folder").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .accessibilityLabel("Duplicate scan scope")

            Picker("Keep rule", selection: $finderModel.keepRule) {
                ForEach(DAMKeepRule.allCases) { rule in
                    Text(rule.displayName).tag(rule)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .help("Which copy to preserve when cleaning duplicates")

            if let scope = finderModel.selectedScope {
                Text(URL(fileURLWithPath: scope).lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .help(scope)
            }

            Spacer()

            if finderModel.mode == .versions {
                Button {
                    finderModel.learnVersionPatterns()
                } label: {
                    Label("Learn from folder…", systemImage: "folder.badge.gear")
                }
                .buttonStyle(.borderless)
            }

            if !finderModel.results.isEmpty || !finderModel.versionSets.isEmpty {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                finderModel.cancelScan()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .opacity(finderModel.isScanning ? 1 : 0)
            .disabled(!finderModel.isScanning)

            Button {
                finderModel.startScan(defaultScope: viewModel.selectedFolder)
            } label: {
                Label(finderModel.isScanning ? "Scanning…" : "Scan", systemImage: "doc.on.doc")
            }
            .disabled(finderModel.isScanning)
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        .padding(12)
    }

    private var summaryText: String {
        switch finderModel.mode {
        case .sha256, .perceptual:
            return "\(finderModel.results.count) groups · \(formatBytes(finderModel.totalWasted)) reclaimable"
        case .versions:
            return "\(finderModel.versionSets.count) sets · \(formatBytes(finderModel.totalWasted)) total"
        }
    }

    // MARK: - Scanning overlay

    private var scanningOverlay: some View {
        VStack(spacing: 8) {
            RetroScanIndicator(message: finderModel.progressText)
            Text(scanningSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
    }

    private var scanningSubtitle: String {
        switch finderModel.mode {
        case .sha256: return "Comparing SHA-256 hashes of same-size files…"
        case .perceptual: return "Matching visual fingerprints (pHash)…"
        case .versions: return "Grouping files by version naming patterns…"
        }
    }

    // MARK: - Error banner

    private var errorBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(finderModel.errorMessage ?? "")
            Spacer()
            Button("Dismiss") { finderModel.errorMessage = nil }
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
    }

    // MARK: - Generate hashes banner

    private var generateHashesBanner: some View {
        HStack {
            Image(systemName: "photo.on.rectangle.angled")
            Text("Some images don’t have a visual fingerprint yet. Generate pHashes to find near-duplicates.")
            Spacer()
            Button("Generate pHashes") {
                finderModel.generateHashes(defaultScope: viewModel.selectedFolder)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1))
    }

    // MARK: - Results list

    private var resultsList: some View {
        List {
            if finderModel.results.isEmpty && finderModel.versionSets.isEmpty && !finderModel.isScanning {
                Section {
                    modeExplanation
                }
            }

            if finderModel.mode == .versions {
                ForEach(finderModel.versionSets) { versionSet in
                    versionSetSection(versionSet)
                }
            } else {
                ForEach(finderModel.results) { group in
                    duplicateGroupSection(group)
                }
            }
        }
        .listStyle(.inset)
    }

    private var modeExplanation: some View {
        switch finderModel.mode {
        case .sha256:
            ContentUnavailableView {
                Label("Find identical files", systemImage: "doc.on.doc")
            } description: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compares the exact SHA-256 hash of every file.")
                    Text("Only files whose bytes are 100% identical are grouped together — renamed files are still found, but files with different metadata are treated as different.")
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            }
        case .perceptual:
            ContentUnavailableView {
                Label("Find visually similar images", systemImage: "photo.on.rectangle")
            } description: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generates a perceptual hash (pHash) from each image.")
                    Text("It groups photos that look alike even if they have been resized, cropped, recompressed, or saved in different formats. Great for finding edited versions, social crops, and alternate exports of the same shot.")
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            }
        case .versions:
            ContentUnavailableView {
                Label("Find versioned files", systemImage: "number")
            } description: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Groups files by their base filename after stripping version suffixes such as _v01, _02, or _final.")
                    Text("Use Learn from folder to teach MaestroDAM your project's naming scheme. Ideal for design iterations, video cuts, and document revisions.")
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            }
        }
    }

    // MARK: - Duplicate group section

    private func duplicateGroupSection(_ group: DAMDuplicateGroup) -> some View {
        Section {
            ForEach(group.items) { item in
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .lineLimit(1)

                    Spacer()

                    if let dimensions = item.formattedDimensions {
                        Text(dimensions)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let date = item.formattedDate {
                        Text(date)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(formatBytes(item.size))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                .contextMenu {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.right.circle")
                    }

                    Button {
                        DAMCleanupListStore.shared.add(path: item.path)
                    } label: {
                        Label("Add to cleanup list", systemImage: "trash")
                    }
                }
            }
        } header: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.count) copies · \(formatBytes(group.fileSize)) each")
                        .font(.subheadline.weight(.semibold))
                    Text("Hash: \(group.hash.prefix(16))… · \(formatBytes(group.wastedSpace)) reclaimable")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    finderModel.addAllButFirstToCleanup(group)
                } label: {
                    Label("Keep \(finderModel.keepRule.displayName.lowercased()), clean rest", systemImage: "sparkles")
                }
                .buttonStyle(.borderless)

                Button {
                    finderModel.addAllToCleanup(group)
                } label: {
                    Label("Add all to cleanup", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Version set section

    private func versionSetSection(_ versionSet: DAMVersionSetFinder.VersionSet) -> some View {
        Section {
            ForEach(versionSet.items) { item in
                HStack(spacing: 8) {
                    Text(URL(fileURLWithPath: item.path).lastPathComponent)
                        .lineLimit(1)

                    Spacer()

                    if let dimensions = item.formattedDimensions {
                        Text(dimensions)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if let date = item.formattedDate {
                        Text(date)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(formatBytes(item.size))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                .contextMenu {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Label("Show in Finder", systemImage: "arrow.right.circle")
                    }

                    Button {
                        DAMCleanupListStore.shared.add(path: item.path)
                    } label: {
                        Label("Add to cleanup list", systemImage: "trash")
                    }
                }
            }
        } header: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(versionSet.count) versions · \(formatBytes(versionSet.totalSize)) total")
                        .font(.subheadline.weight(.semibold))
                    Text("Base: \(URL(fileURLWithPath: versionSet.baseKey).lastPathComponent)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    finderModel.addAllButKeeperToCleanup(versionSet)
                } label: {
                    Label("Keep \(finderModel.keepRule.displayName.lowercased()), clean rest", systemImage: "sparkles")
                }
                .buttonStyle(.borderless)

                Button {
                    for item in versionSet.items {
                        DAMCleanupListStore.shared.add(path: item.path)
                    }
                } label: {
                    Label("Add all to cleanup", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Item formatting helpers

private extension DAMDuplicateItem {
    var formattedDimensions: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }

    var formattedDate: String? {
        guard let date = captureDate ?? fileModDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
