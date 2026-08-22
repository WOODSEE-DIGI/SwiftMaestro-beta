import Foundation
import SwiftUI

// MARK: - Tagging Workspace View Model
//
// Drives the Tagging workspace: the pending-suggestion queue, the untagged
// "tag these" strip, background AI indexing progress, and threshold tuning.
// Follows the project-wide `@Observable @MainActor` store pattern; all work
// is delegated to the `DAMTaggingService` actor.

@Observable
@MainActor
final class DAMTaggingViewModel {

    // MARK: State

    /// Pending suggestions at/above the review threshold, paired with their
    /// assets, highest confidence first.
    private(set) var queue: [(suggestion: DAMTagSuggestion, asset: DAMAsset)] = []
    /// Untagged assets feeding the bottom "tag these" filmstrip.
    private(set) var untaggedPool: [DAMAsset] = []
    /// Tag names on the primary selection (tag tree, not userKeywords).
    private(set) var primaryTags: [String] = []
    /// OCR text of the primary selection (from the asset row).
    private(set) var primaryOCR: String?

    private(set) var backlogCount = 0
    private(set) var pendingCount = 0
    private(set) var isIndexing = false
    private(set) var indexProgress = ""
    private(set) var isPropagating = false
    private(set) var statusMessage: String?

    var thresholds = DAMTaggingService.Thresholds.load() {
        didSet { thresholds.save() }
    }

    private let database: DAMDatabase
    private let service: DAMTaggingService
    private var indexTask: Task<Void, Never>?

    init(database: DAMDatabase = .shared, service: DAMTaggingService = .shared) {
        self.database = database
        self.service = service
    }

    // MARK: - Loading

    /// Full refresh of the queue, strip, and counters.
    func reload() async {
        let minConfidence = thresholds.suggest
        do {
            async let suggestionsTask = Task.detached(priority: .userInitiated) { [database] in
                try database.pendingSuggestions(minConfidence: minConfidence, limit: 500)
            }.value
            async let untaggedTask = Task.detached(priority: .userInitiated) { [database] in
                try database.untaggedAssets(requireFeatures: false, limit: 300, offset: 0)
            }.value
            async let backlogTask = Task.detached(priority: .userInitiated) { [database] in
                try database.featureBacklogCount()
            }.value
            async let pendingTask = Task.detached(priority: .userInitiated) { [database] in
                try database.pendingSuggestionCount(minConfidence: 0)
            }.value
            queue = try await suggestionsTask
            untaggedPool = try await untaggedTask
            backlogCount = try await backlogTask
            pendingCount = try await pendingTask
        } catch {
            statusMessage = "Failed to load tagging state: \(error.localizedDescription)"
        }
    }

    /// Refresh the tag list + OCR text for the given (primary) asset.
    func loadPrimaryDetails(_ asset: DAMAsset?) async {
        guard let asset, let assetId = asset.id else {
            primaryTags = []
            primaryOCR = nil
            return
        }
        primaryOCR = asset.ocrText
        primaryTags = (try? await Task.detached(priority: .userInitiated) { [database] in
            try database.tagNames(forAssetId: assetId)
        }.value) ?? []
    }

    // MARK: - Indexing

    /// Run the OCR + feature-print indexing pass over the backlog.
    func startIndexing() {
        guard !isIndexing else { return }
        isIndexing = true
        indexProgress = "Starting…"
        indexTask = Task {
            do {
                let result = try await service.indexFeatures { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.indexProgress = progress.currentFile.isEmpty
                            ? "Indexed \(progress.updated) of \(progress.total)"
                            : "\(progress.scanned)/\(progress.total) — \(progress.currentFile)"
                    }
                }
                statusMessage = "Indexing complete: \(result.updated) assets analyzed "
                    + "(OCR + visual fingerprints)."
            } catch is CancellationError {
                statusMessage = "Indexing paused — run again to resume."
            } catch {
                statusMessage = "Indexing failed: \(error.localizedDescription)"
            }
            isIndexing = false
            indexProgress = ""
            await reload()
        }
    }

    func cancelIndexing() {
        indexTask?.cancel()
    }

    // MARK: - Manual tagging (learn-on-tag)

    /// Apply comma-separated tags to a set of assets (source `user`), then
    /// propagate from each — every tag teaches the engine.
    func applyTagsAndLearn(_ raw: String, to assetIds: Set<DAMAsset.ID>) async {
        let ids = assetIds.compactMap { $0 }
        let names = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !ids.isEmpty, !names.isEmpty else { return }
        isPropagating = true
        var totalNew = 0
        do {
            for id in ids {
                totalNew += try await service.applyTagAndLearn(assetId: id, names: names)
            }
            statusMessage = totalNew > 0
                ? "Tagged \(ids.count) asset(s) — \(totalNew) new suggestions from similar images."
                : "Tagged \(ids.count) asset(s). No similar images found yet "
                  + "(index more assets to improve matching)."
        } catch {
            statusMessage = "Tagging failed: \(error.localizedDescription)"
        }
        isPropagating = false
        await reload()
    }

    // MARK: - Suggestion resolution

    func accept(_ suggestion: DAMTagSuggestion) async {
        guard let id = suggestion.id else { return }
        do {
            try await service.acceptSuggestion(id: id)
            queue.removeAll { $0.suggestion.id == id }
            pendingCount = max(0, pendingCount - 1)
        } catch {
            statusMessage = "Accept failed: \(error.localizedDescription)"
        }
    }

    func reject(_ suggestion: DAMTagSuggestion) async {
        guard let id = suggestion.id else { return }
        do {
            try await service.rejectSuggestion(id: id)
            queue.removeAll { $0.suggestion.id == id }
            pendingCount = max(0, pendingCount - 1)
        } catch {
            statusMessage = "Reject failed: \(error.localizedDescription)"
        }
    }

    /// Bulk-accept everything at/above the auto-apply threshold shown in UI.
    func acceptAllAboveThreshold() async {
        isPropagating = true
        do {
            let count = try await service.acceptAll(minConfidence: thresholds.autoApply)
            statusMessage = "Accepted \(count) suggestions "
                + "(≥ \(Int(thresholds.autoApply * 100))% confidence)."
        } catch {
            statusMessage = "Bulk accept failed: \(error.localizedDescription)"
        }
        isPropagating = false
        await reload()
    }

    /// Full-catalog relearn: propagate from EVERY tagged exemplar (manual
    /// tags + Lightroom-imported keywords). Background, cancellable via
    /// starting another action (service throws CancellationError through).
    func relearnFromAllExemplars() async {
        guard !isPropagating else { return }
        isPropagating = true
        statusMessage = "Learning from all tagged assets…"
        do {
            let created = try await service.propagateFromAllExemplars { done, total, suggestions in
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Learning: \(done)/\(total) exemplars — "
                        + "\(suggestions) suggestions so far"
                }
            }
            statusMessage = "Relearn complete: \(created) suggestions "
                + "propagated from all tagged assets."
        } catch is CancellationError {
            statusMessage = "Relearn cancelled."
        } catch {
            statusMessage = "Relearn failed: \(error.localizedDescription)"
        }
        isPropagating = false
        await reload()
    }

    // MARK: - Presentation helpers

    /// Queue grouped by tag name, ordered by each group's top confidence.
    var groupedQueue: [(tag: String, items: [(suggestion: DAMTagSuggestion, asset: DAMAsset)])] {
        var groups: [String: [(DAMTagSuggestion, DAMAsset)]] = [:]
        for item in queue { groups[item.suggestion.tagName, default: []].append(item) }
        return groups
            .map { (tag: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                (lhs.items.map(\.suggestion.confidence).max() ?? 0)
                    > (rhs.items.map(\.suggestion.confidence).max() ?? 0)
            }
    }

    static func basisIcon(_ basis: DAMSuggestionBasis) -> String {
        switch basis {
        case .visual: return "eye"
        case .ocr: return "text.viewfinder"
        case .both: return "sparkles"
        }
    }

    static func basisLabel(_ basis: DAMSuggestionBasis) -> String {
        switch basis {
        case .visual: return "Visual match"
        case .ocr: return "OCR text match"
        case .both: return "Visual + text match"
        }
    }
}
