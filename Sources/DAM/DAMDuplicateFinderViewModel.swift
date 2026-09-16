import Foundation
import SwiftUI

// MARK: - Mode

enum DAMDuplicateFinderMode: String, CaseIterable, Sendable, Identifiable {
    case sha256 = "sha256"
    case perceptual = "perceptual"
    case versions = "versions"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sha256: return "SHA-256 exact"
        case .perceptual: return "Visual (pHash)"
        case .versions: return "Version sets"
        }
    }

    var icon: String {
        switch self {
        case .sha256: return "doc.on.doc"
        case .perceptual: return "photo.on.rectangle"
        case .versions: return "number"
        }
    }
}

// MARK: - View model

/// View model for the duplicate finder UI. Isolated to the main actor so it
/// can own `@Observable` state and act as the scanner delegate.
@MainActor
@Observable
final class DAMDuplicateFinderViewModel: DAMDuplicateFinderDelegate {
    var mode: DAMDuplicateFinderMode = .sha256
    var selectedScope: String?
    var keepRule: DAMKeepRule = .largestResolution

    var isScanning = false
    var progressText = ""
    var results: [DAMDuplicateGroup] = []
    var versionSets: [DAMVersionSetFinder.VersionSet] = []
    var totalWasted: Int64 = 0
    var errorMessage: String?
    var learnedPatterns: [DAMVersionPattern] = []
    var missingHashCount: Int?

    private var scanTask: Task<Void, Never>?

    /// Whether the current mode needs pHashes and some are missing.
    var needsPerceptualHashGeneration: Bool {
        mode == .perceptual
            && !isScanning
            && results.isEmpty
            && errorMessage == nil
            && (missingHashCount ?? 0) > 0
    }

    /// Start scanning based on the selected mode and scope.
    func startScan(defaultScope: String?) {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        results = []
        versionSets = []
        totalWasted = 0
        learnedPatterns = []

        let status = DAMResourceStatus.shared
        let limit = status.lastLimit?.maxConcurrentHeavyTasks ?? 1
        if status.activeHeavyTasks >= limit || status.queuedHeavyTasks > 0 {
            progressText = "Waiting for another heavy task to finish…"
        } else {
            progressText = "Preparing scan…"
        }

        let scope = selectedScope ?? defaultScope

        switch mode {
        case .sha256:
            scanTask = Task { await runSHA256Scan(scope: scope) }
        case .perceptual:
            scanTask = Task { await runPerceptualScan(scope: scope) }
        case .versions:
            scanTask = Task { await runVersionScan(scope: scope) }
        }
    }

    /// Generates missing pHashes for the selected scope.
    func generateHashes(defaultScope: String?) {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        progressText = "Generating visual fingerprints…"

        let scope = selectedScope ?? defaultScope
        scanTask = Task {
            defer { isScanning = false }
            do {
                let count = try await DAMDuplicateFinder.shared.generatePerceptualHashes(
                    in: scope,
                    delegate: self
                )
                progressText = "Generated \(count) pHashes"
                missingHashCount = 0
                // Auto-start the perceptual scan after hashes are ready.
                await runPerceptualScan(scope: scope)
            } catch is CancellationError {
                // no-op
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Refreshes the count of images in scope that still need a pHash.
    /// Used to decide whether to show the "Generate pHashes" banner.
    func refreshMissingHashCount(defaultScope: String?) {
        let scope = selectedScope ?? defaultScope
        guard mode == .perceptual else { return }
        Task {
            do {
                let count = try await DAMDuplicateFinder.shared.countMissingPerceptualHashes(in: scope)
                self.missingHashCount = count
            } catch {
                self.missingHashCount = nil
            }
        }
    }

    /// Opens a folder panel, learns version patterns from the selected folder,
    /// and stores them for future version-set scans.
    func learnVersionPatterns() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder that uses your version naming scheme"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let patterns = await DAMVersionPatternLearner.learn(from: url.path)
            learnedPatterns = patterns
        }
    }

    func cancelScan() {
        Task {
            await DAMDuplicateFinder.shared.cancel()
        }
        scanTask?.cancel()
        scanTask = nil
    }

    // MARK: - Scan runners

    private func runSHA256Scan(scope: String?) async {
        defer {
            isScanning = false
            progressText = ""
        }
        do {
            let groups = try await DAMDuplicateFinder.shared.findDuplicates(
                in: scope,
                delegate: self
            )
            self.results = groups
            self.totalWasted = groups.reduce(0) { $0 + $1.wastedSpace }
        } catch is CancellationError {
            // no-op
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func runPerceptualScan(scope: String?) async {
        defer {
            isScanning = false
            if results.isEmpty && errorMessage == nil {
                progressText = "No visual duplicates found"
            } else {
                progressText = ""
            }
        }
        do {
            let groups = try await DAMDuplicateFinder.shared.findPerceptualDuplicates(in: scope)
            self.results = groups
            self.totalWasted = groups.reduce(0) { $0 + $1.wastedSpace }
            if groups.isEmpty {
                // Refresh the missing-hash count so the banner/empty state is accurate.
                let count = try await DAMDuplicateFinder.shared.countMissingPerceptualHashes(in: scope)
                self.missingHashCount = count
            }
        } catch is CancellationError {
            // no-op
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func runVersionScan(scope: String?) async {
        defer {
            isScanning = false
            progressText = ""
        }
        do {
            let sets = try await DAMVersionSetFinder.shared.findVersionSets(in: scope)
            self.versionSets = sets
            self.totalWasted = sets.reduce(0) { $0 + $1.totalSize }
            if sets.isEmpty {
                progressText = "No version sets found"
            }
        } catch is CancellationError {
            // no-op
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Cleanup helpers

    func addAllButFirstToCleanup(_ group: DAMDuplicateGroup) {
        let keeper = keepRule.keeper(among: group.items)
        let toRemove = keeper == nil ? group.items : group.items.filter { $0.path != keeper!.path }
        for item in toRemove {
            DAMCleanupListStore.shared.add(path: item.path)
        }
    }

    func addAllToCleanup(_ group: DAMDuplicateGroup) {
        for item in group.items {
            DAMCleanupListStore.shared.add(path: item.path)
        }
    }

    func addAllButKeeperToCleanup(_ versionSet: DAMVersionSetFinder.VersionSet) {
        let keeper = keepRule.keeper(among: versionSet.items)
        let toRemove = keeper == nil ? versionSet.items : versionSet.items.filter { $0.path != keeper!.path }
        for item in toRemove {
            DAMCleanupListStore.shared.add(path: item.path)
        }
    }

    // MARK: - DAMDuplicateFinderDelegate

    nonisolated func duplicateFinder(
        _ finder: DAMDuplicateFinder,
        didUpdate progress: DAMDuplicateFinder.Progress
    ) {
        Task { @MainActor in
            progressText = "Hashed \(progress.hashed) of \(progress.total) files"
        }
    }
}
