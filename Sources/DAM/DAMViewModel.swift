import AppKit
import Foundation

// MARK: - MaestroDAM Browser View Model
//
// Drives the DAM browser panel: paged grid loading, FTS5 search, minimum
// rating filter, folder import with progress, and rating edits. Follows the
// project-wide `@Observable @MainActor` store pattern (see
// `AppEnablementStore`/`WorkspaceLayoutState`).

@Observable
@MainActor
final class DAMViewModel {

    // MARK: State

    private(set) var assets: [DAMAsset] = []
    var selection: Set<DAMAsset.ID> = []
    /// The anchor/primary of the selection — drives previews and the
    /// filmstrip scroll position. Tracked EXPLICITLY: `Set.first` is
    /// non-deterministic across mutations (rehashing on ⌘-click can make a
    /// different element "first"), which made `primaryAsset` flap between
    /// assets — every task(id:)/onChange observing it then refired
    /// ("tried to update multiple times per frame") and the preview
    /// flickered between different images.
    private(set) var primarySelectedID: DAMAsset.ID = nil
    var searchText = "" {
        didSet { scheduleSearch() }
    }
    var minimumRating = 0 {
        didSet { Task { await reload() } }
    }
    var sortOrder: DAMDatabase.DAMSortOrder = .captureDateDesc {
        didSet { Task { await reload() } }
    }
    /// Folder-tree scope (nil = whole catalog). Mirrors Bridge's Folders tab.
    var selectedFolder: String? {
        didSet {
            clearSelection()
            Task { await reload() }
        }
    }
    /// Active workspace layout (tab bar under the toolbar). Persisted across
    /// launches. Legacy stored values (e.g. "essentials" from before the
    /// Home rename) fall through to the .home default.
    var workspace: DAMWorkspace = {
        DAMWorkspace(rawValue: UserDefaults.standard.string(forKey: "dam.workspace") ?? "")
            ?? .home
    }() {
        didSet { UserDefaults.standard.set(workspace.rawValue, forKey: "dam.workspace") }
    }
    private(set) var folderTree: [DAMFolderNode] = []
    private(set) var totalAssetCount = 0
    private(set) var isImporting = false
    private(set) var importScanned = 0
    private(set) var importWritten = 0
    private(set) var errorMessage: String?

    /// The single selected asset, when exactly one row is selected — drives
    /// the Bridge-style Preview + File Properties panel.
    var selectedAsset: DAMAsset? {
        guard selection.count == 1 else { return nil }
        return primaryAsset
    }

    /// The primary selected asset regardless of selection count — drives the
    /// big preview in Filmstrip/Libraries and the preview panel header.
    var primaryAsset: DAMAsset? {
        guard let id = primarySelectedID else { return nil }
        return assets.first { $0.id == id }
    }

    /// Single-select (plain click). Idempotent — @Observable notifies on
    /// EVERY write (no equality dedupe), so re-asserted identical values
    /// must no-op or they feed SwiftUI update cycles (AttributeGraph loop
    /// with Table(selection:) re-assertion → "onChange tried to update
    /// multiple times per frame").
    func selectSingle(_ id: DAMAsset.ID) {
        guard selection != [id] || primarySelectedID != id else { return }
        selection = [id]
        primarySelectedID = id
    }

    /// Replace the selection (Table/list views drive this via a Binding).
    /// Keeps the current primary if it's still selected. Idempotent — the
    /// Table re-asserts the same selection during its own update pass; a
    /// no-op guard breaks the feedback cycle. Crucially the primary write
    /// is guarded by REAL change: @Observable notifies on EVERY write
    /// (even nil→nil), and an unguarded `primarySelectedID = ids.first ?? nil`
    /// on an empty re-assertion looped the AttributeGraph
    /// ("onChange(of: Optional<Int64>) tried to update multiple times
    /// per frame").
    func setSelection(_ ids: Set<DAMAsset.ID>) {
        if selection != ids {
            selection = ids
        }
        let desired = resolvedPrimary(for: ids)
        if desired != primarySelectedID {
            primarySelectedID = desired
        }
    }

    /// The primary for a given selection: keep the current one if it's
    /// still selected, else fall back to any member (or nil when empty).
    private func resolvedPrimary(for ids: Set<DAMAsset.ID>) -> DAMAsset.ID {
        if let current = primarySelectedID, ids.contains(current) { return current }
        return ids.first ?? nil
    }

    /// Toggle a row in/out of the selection (⌘-click semantics). The most
    /// recently clicked row becomes primary (Finder/Bridge behavior).
    func toggleSelection(_ id: DAMAsset.ID) {
        guard let id else { return }
        if selection.contains(id) {
            selection.remove(id)
            if primarySelectedID == id {
                primarySelectedID = selection.first ?? nil
            }
        } else {
            selection.insert(id)
            primarySelectedID = id
        }
    }

    /// Clear the selection (folder change). Idempotent.
    func clearSelection() {
        guard !selection.isEmpty || primarySelectedID != nil else { return }
        selection = []
        primarySelectedID = nil
    }

    private let pageSize = 500
    private var canLoadMore = true
    private var searchTask: Task<Void, Never>?

    private let database: DAMDatabase

    init(database: DAMDatabase = .shared) {
        self.database = database
    }

    // MARK: - Loading

    /// Initial load / full refresh honoring current filters.
    func reload() async {
        do {
            let folder = selectedFolder
            let rating = minimumRating
            async let page = fetchPage(offset: 0)
            async let count = Task.detached(priority: .userInitiated) { [database] in
                try database.assetCount(folder: folder, minRating: rating)
            }.value
            assets = try await page
            totalAssetCount = (try? await count) ?? assets.count
            canLoadMore = assets.count == pageSize
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load catalog: \(error.localizedDescription)"
        }
    }

    /// Rebuilds the folder-tree sidebar from the catalog's distinct folders.
    /// Called on appear and after each import — NOT on every reload (search
    /// keystrokes shouldn't re-query thousands of folders).
    func refreshFolderTree() async {
        do {
            let counts = try await Task.detached(priority: .userInitiated) { [database] in
                try database.folderCounts()
            }.value
            folderTree = Self.buildTree(from: counts)
        } catch {
            NSLog("[DAM] folder tree refresh failed: %@", String(describing: error))
        }
    }

    /// Builds the nested folder tree from flat (folder, count) rows.
    /// Nonisolated so the (potentially thousands of) inserts never touch
    /// the main thread.
    nonisolated static func buildTree(
        from counts: [(folder: String, count: Int)]
    ) -> [DAMFolderNode] {
        final class MutableNode {
            var count = 0
            var children: [String: MutableNode] = [:]
        }
        let root = MutableNode()
        for (folder, count) in counts {
            let components = folder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var node = root
            for component in components {
                let child = node.children[component] ?? MutableNode()
                node.children[component] = child
                node = child
            }
            node.count = count
        }
        func convert(_ name: String, _ node: MutableNode, path: String) -> DAMFolderNode? {
            let children: [DAMFolderNode] = node.children.keys.sorted().compactMap { key in
                node.children[key].flatMap { convert(key, $0, path: path + "/" + key) }
            }
            return DAMFolderNode(
                path: path, name: name, count: node.count,
                children: children.isEmpty ? nil : children)
        }
        return root.children.keys.sorted().compactMap { key in
            root.children[key].flatMap { convert(key, $0, path: "/" + key) }
        }
    }

    /// Next page for infinite scroll. Serialized: bottom-of-grid cells can
    /// be re-inserted rapidly at the pagination boundary, and overlapping
    /// appends churn the grid (visible as boundary-cell flicker).
    private var isLoadingMore = false

    func loadMoreIfNeeded(currentItem: DAMAsset) async {
        guard canLoadMore,
              !isLoadingMore,
              let last = assets.last,
              currentItem.id == last.id else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetchPage(offset: assets.count)
            assets.append(contentsOf: page)
            canLoadMore = page.count == pageSize
        } catch {
            errorMessage = "Failed to load more assets: \(error.localizedDescription)"
        }
    }

    private func fetchPage(offset: Int) async throws -> [DAMAsset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rating = minimumRating
        let folder = selectedFolder
        let sort = sortOrder
        let limit = pageSize
        return try await Task.detached(priority: .userInitiated) { [database] in
            if query.isEmpty {
                return try database.assets(
                    folder: folder, minRating: rating, sort: sort,
                    limit: limit, offset: offset)
            }
            let ids = try database.searchAssetIDs(matching: query, folder: folder, limit: limit)
            guard !ids.isEmpty else { return [DAMAsset]() }
            let found = try await database.dbQueue.read { db in
                try DAMAsset.fetchAll(db, keys: ids)
            }
            // Preserve FTS rank order (fetchAll(keys:) is unordered).
            let byID = Dictionary(found.map { ($0.id ?? -1, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }
        }.value
    }

    // MARK: - Search debounce

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            await self.reload()
        }
    }

    // MARK: - Import

    /// Prompt for a folder and import its contents.
    func importFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to import into the MaestroDAM catalog"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importFolder(url) }
    }

    func importFolder(_ url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        importScanned = 0
        importWritten = 0
        defer { isImporting = false }

        do {
            try await DAMImportService.shared.importFolder(at: url) { [weak self] scanned, written in
                Task { @MainActor in
                    guard let self else { return }
                    self.importScanned = scanned
                    self.importWritten = written
                    // Progressive fill: refresh the grid every 5K cataloged
                    // rows so a huge import doesn't leave the panel empty
                    // until the very end. WAL mode makes these reads safe
                    // alongside the import's writer; thumbnails come from
                    // cache so re-renders are cheap.
                    if written % 5_000 == 0 {
                        await self.reload()
                    }
                }
            }
            await reload()
            await refreshFolderTree()
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Rating edits

    /// Set rating (0–5) for every selected asset and persist.
    func setRating(_ rating: Int, for ids: Set<DAMAsset.ID>) async {
        let int64IDs = ids.compactMap { $0 }
        guard !int64IDs.isEmpty else { return }
        do {
            try await database.dbQueue.write { db in
                for var asset in try DAMAsset.fetchAll(db, keys: int64IDs) {
                    guard let assetId = asset.id else { continue }
                    let oldRating = asset.rating
                    guard oldRating != rating else { continue }
                    asset.rating = rating
                    try asset.update(db)
                    // Audit trail — every metadata change is rollback-able.
                    try database.recordAudit(
                        db, assetId: assetId, field: "rating",
                        oldValue: "\(oldRating)", newValue: "\(rating)",
                        source: "user")
                }
            }
            for index in assets.indices where int64IDs.contains(assets[index].id ?? -1) {
                assets[index].rating = rating
            }
        } catch {
            errorMessage = "Failed to update rating: \(error.localizedDescription)"
        }
    }

    // MARK: - Batch keywords (Edit workspace)

    /// Add-to or replace the user keywords of every selected asset. Audited.
    enum KeywordApplyMode: String, CaseIterable, Sendable {
        case add = "Add"
        case replace = "Replace"
    }

    func applyUserKeywords(_ raw: String, mode: KeywordApplyMode,
                           to ids: Set<DAMAsset.ID>) async {
        let int64IDs = ids.compactMap { $0 }
        guard !int64IDs.isEmpty else { return }
        let parsed = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parsed.isEmpty || mode == .replace else {
            errorMessage = "Enter at least one keyword (comma-separated)."
            return
        }
        do {
            try await database.dbQueue.write { db in
                for var asset in try DAMAsset.fetchAll(db, keys: int64IDs) {
                    guard let assetId = asset.id else { continue }
                    let oldValue = asset.userKeywords ?? ""
                    let existing = oldValue.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let merged: [String]
                    switch mode {
                    case .replace:
                        merged = parsed
                    case .add:
                        merged = existing + parsed.filter { !existing.contains($0) }
                    }
                    let newValue = merged.isEmpty ? nil : merged.joined(separator: ", ")
                    guard newValue != asset.userKeywords else { continue }
                    asset.userKeywords = newValue
                    try asset.update(db)
                    try database.recordAudit(
                        db, assetId: assetId, field: "userKeywords",
                        oldValue: oldValue.isEmpty ? nil : oldValue,
                        newValue: newValue, source: "user")
                }
            }
            for index in assets.indices where int64IDs.contains(assets[index].id ?? -1) {
                let existing = (assets[index].userKeywords ?? "").split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let merged = mode == .replace
                    ? parsed
                    : existing + parsed.filter { !existing.contains($0) }
                assets[index].userKeywords = merged.isEmpty ? nil : merged.joined(separator: ", ")
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed to update keywords: \(error.localizedDescription)"
        }
    }

    // MARK: - Selection export (Output workspace)

    /// Resolve the full selection to catalog rows — the selection may span
    /// folders beyond the currently loaded grid page.
    func assets(for ids: Set<DAMAsset.ID>) async -> [DAMAsset] {
        let keys = ids.compactMap { $0 }
        guard !keys.isEmpty else { return [] }
        return (try? await Task.detached(priority: .userInitiated) { [database] in
            try database.fetchAssets(ids: keys)
        }.value) ?? []
    }

    private(set) var isExporting = false
    private(set) var exportProgressDone = 0
    private(set) var exportProgressTotal = 0
    private(set) var exportCurrentFile = ""
    private(set) var lastExportResult: DAMExportService.ExportResult?

    /// Export the current selection. The heavy decode/copy work runs in
    /// `DAMExportService` (nonisolated); progress hops back to MainActor.
    func exportSelection(
        preset: DAMExportService.ExportPreset,
        destination: URL
    ) async {
        guard !isExporting, !selection.isEmpty else { return }
        isExporting = true
        exportProgressDone = 0
        exportCurrentFile = ""
        lastExportResult = nil
        let assets = await assets(for: selection)
        exportProgressTotal = assets.count
        let result = await DAMExportService.export(
            assets: assets, preset: preset, destination: destination
        ) { [weak self] done, total, name in
            Task { @MainActor [weak self] in
                self?.exportProgressDone = done
                self?.exportProgressTotal = total
                self?.exportCurrentFile = name
            }
        }
        lastExportResult = result
        isExporting = false
    }
}
