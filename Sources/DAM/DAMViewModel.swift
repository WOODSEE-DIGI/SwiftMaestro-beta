import AppKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

// MARK: - Notification for agent-driven filter updates

extension Notification.Name {
    /// Posted by the `dam_filter_view` tool to push filter state into the
    /// DAM browser panel.  `userInfo` keys match the tool parameters:
    /// search, tag_color, file_type, flag, min_rating, sort, folder, clear.
    static let damApplyFilters = Notification.Name(
        "com.woodseedigi.swiftmaestro.damApplyFilters")
}

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
    /// Filter by tag color (nil = all, 2-7 = specific color)
    var filterTagColor: Int? = nil {
        didSet { Task { await reload() } }
    }
    /// Filter by file type category (nil = all)
    var filterFileType: String? = nil {
        didSet { Task { await reload() } }
    }
    /// Show only tagged or untagged files (nil = all)
    var filterTagged: Bool? = nil {
        didSet { Task { await reload() } }
    }
    /// Filter by flag (nil = all)
    var filterFlag: DAMFlag? = nil {
        didSet { Task { await reload() } }
    }
    /// Whether redaction boxes are drawn on previews. Original files are never
    /// modified; this only affects the live preview/edit render and is always
    /// forced ON for exports. Useful for reviewing originals vs. redacted
    /// versions and for screen-recording workflows.
    var showRedactions: Bool = true
    /// Privacy mode: one-click redaction toggle for screen sharing/recordings.
    /// Activating it turns redaction rendering on, makes existing layers
    /// visible, and auto-redacts visible/upcoming assets that have no
    /// redactions yet.
    var privacyModeActive: Bool = false
    /// Number of assets still being scanned by privacy redaction.
    private(set) var privacyScanningCount: Int = 0
    /// Folder-tree scope (nil = whole catalog). Mirrors Bridge's Folders tab.
    var selectedFolder: String? {
        didSet {
            guard selectedFolder != oldValue else { return }
            if selectedFolder != nil { selectedCollectionID = nil }
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
    /// Mounted local volumes shown in the Folders sidebar (e.g. Macintosh HD).
    /// These are not catalog folders; they exist so Storage Map can scan them.
    private(set) var volumeNodes: [DAMFolderNode] = []
    /// User-created collections/albums.
    private(set) var collections: [DAMCollection] = []
    /// Cached asset counts per collection ID.
    private(set) var collectionAssetCounts: [Int64: Int] = [:]
    /// Selected collection ID (nil = not browsing a collection).
    var selectedCollectionID: Int64? {
        didSet {
            clearSelection()
            Task { await reload() }
        }
    }
    private(set) var totalAssetCount = 0
    private(set) var isImporting = false
    private(set) var importScanned = 0
    private(set) var importWritten = 0
    private(set) var errorMessage: String?

    /// Expose a setter so views can report errors without making the
    /// property publicly mutable everywhere.
    func setErrorMessage(_ message: String?) {
        errorMessage = message
    }

    /// Folder path → Finder tag color indices, for colored dots in the
    /// folder tree sidebar. Populated during refreshFolderTree.
    private(set) var folderTagColors: [String: [Int]] = [:]

    /// The single selected asset, when exactly one row is selected — drives
    /// the Bridge-style Preview + File Properties panel.
    var selectedAsset: DAMAsset? {
        guard selection.count == 1 else { return nil }
        return primaryAsset
    }

    /// The primary selected asset regardless of selection count — drives the
    /// Edit page, the Metadata panel, and the preview panel header.
    /// Resolves against the loaded page first (always the freshest row), then
    /// falls back to the catalog: sort/rating/type/tag/flag/search reloads
    /// replace the page WITHOUT clearing the selection, and page-only
    /// resolution made previews vanish — and the Edit tab fall back to the
    /// batch tools — for a selection the status bar still showed. A PK
    /// lookup is microseconds and only fires while the id is off-page.
    var primaryAsset: DAMAsset? {
        guard let id = primarySelectedID else { return nil }
        if let inPage = assets.first(where: { $0.id == id }) { return inPage }
        return try? database.asset(withId: id)
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
        // On-demand enrichment: read metadata for this file immediately.
        enrichIfNeeded(id)
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

    // MARK: - Geometry edits (toolbar)

    /// Rotate every selected asset 90° in the requested direction.
    /// Non-destructive: increments/decrements the per-asset edit recipe.
    /// Note: Core Graphics positive rotation is counter-clockwise, so a
    /// clockwise 90° turn is represented as +3 quarter-turns.
    func rotateSelectedAssets(clockwise: Bool = true) {
        let ids = selection.compactMap { $0 }
        guard !ids.isEmpty else { return }
        let delta = clockwise ? 3 : 1
        for id in ids {
            var recipe = DAMDatabase.shared.loadEdits(assetId: id) ?? DAMEditState()
            recipe.rotateQuarterTurns = (recipe.rotateQuarterTurns + delta) % 4
            try? DAMDatabase.shared.saveEdits(assetId: id, recipe)
        }
    }

    // MARK: - Privacy / screen-recording redaction

    /// Toggle global privacy mode. When enabled, existing redaction layers are
    /// shown and any visible/likely-visible asset without redactions gets a
    /// quick AI face-redaction pass.
    func togglePrivacyMode() {
        privacyModeActive.toggle()
        if privacyModeActive {
            showRedactions = true
            Task.detached { [weak self] in
                await self?.applyPrivacyRedactionsToVisibleAssets()
            }
        } else {
            showRedactions = false
        }
    }

    /// Ensure visible + next-scroll assets are redacted.
    private func applyPrivacyRedactionsToVisibleAssets() async {
        let targets = await MainActor.run { [weak self] in
            self?.privacyTargetAssets() ?? []
        }
        guard !targets.isEmpty else { return }

        await MainActor.run { [weak self] in
            self?.privacyScanningCount = targets.count
        }
        defer {
            Task { @MainActor [weak self] in
                self?.privacyScanningCount = 0
            }
        }

        let options = DAMRedactionDetectorService.Options(
            detectFaces: true,
            detectText: true,
            detectBarcodes: true,
            textPatterns: DAMRedactionDetectorService.Options.piiPatterns,
            minimumConfidence: 0.3,
            kind: .blur
        )

        for (index, asset) in targets.enumerated() {
            guard let assetId = asset.id else { continue }
            var recipe = DAMDatabase.shared.loadEdits(assetId: assetId) ?? DAMEditState()
            _ = recipe.defaultRedactionLayerID()

            // Make any existing hidden layers visible.
            var madeVisible = false
            for i in recipe.redactionLayers.indices where !recipe.redactionLayers[i].isVisible {
                recipe.redactionLayers[i].isVisible = true
                madeVisible = true
            }

            // If visible redactions already exist, just persist visibility.
            if !recipe.visibleRedactions().isEmpty {
                if madeVisible {
                    try? DAMDatabase.shared.saveEdits(assetId: assetId, recipe)
                }
                await MainActor.run { [weak self] in
                    self?.privacyScanningCount = targets.count - index - 1
                }
                continue
            }

            // No redactions yet — run a fast face-only detection pass.
            guard FileManager.default.fileExists(atPath: asset.path) else {
                await MainActor.run { [weak self] in
                    self?.privacyScanningCount = targets.count - index - 1
                }
                continue
            }
            do {
                let detected = try await DAMRedactionDetectorService.shared.detect(
                    at: asset.path, options: options)
                if !detected.isEmpty {
                    let privacyLayer = DAMEditState.RedactionLayer(
                        name: "Privacy", isVisible: true)
                    recipe.redactionLayers.append(privacyLayer)
                    recipe.redactions.append(contentsOf: detected.map { box in
                        var copy = box
                        copy.id = UUID()
                        copy.layerID = privacyLayer.id
                        return copy
                    })
                    try? DAMDatabase.shared.saveEdits(assetId: assetId, recipe)
                }
            } catch {
                NSLog("[Privacy] detection failed for %@: %@", asset.path, "\(error)")
            }

            await MainActor.run { [weak self] in
                self?.privacyScanningCount = targets.count - index - 1
            }
        }
    }

    /// Assets that should be redacted for privacy mode: current selection
    /// first, then the first portion of the loaded page as a prefetch buffer.
    @MainActor
    private func privacyTargetAssets() -> [DAMAsset] {
        var result: [DAMAsset] = []
        let selected = assets.filter { selection.contains($0.id) }
        result.append(contentsOf: selected)
        let selectedIDs = Set(selected.compactMap(\.id))
        let remaining = assets.filter { !selectedIDs.contains($0.id ?? 0) }
            .prefix(privacyPrefetchCount)
        result.append(contentsOf: remaining)
        return result
    }

    private let privacyPrefetchCount = 100

    /// Reveal an asset given its filesystem path: select it, switch to the
    /// metadata workspace, and scope the folder tree. If the path isn't in the
    /// catalog yet, import its parent folder first.
    func revealAsset(atPath path: String) async {
        let normalized = (path as NSString).standardizingPath
        if let asset = try? database.asset(withPath: normalized) {
            selectSingle(asset.id)
            selectedFolder = asset.folder
            workspace = .metadata
            await reload()
            return
        }
        let url = URL(fileURLWithPath: normalized)
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        _ = try? await DAMImportService.shared.importFolder(at: parent, database: database)
        if let asset = try? database.asset(withPath: normalized) {
            selectSingle(asset.id)
            selectedFolder = asset.folder
            workspace = .metadata
            await reload()
        }
    }

    private let pageSize = 500
    private var canLoadMore = true
    private var searchTask: Task<Void, Never>?
    private var importTask: Task<Int, any Error>?

    // MARK: - Offload

    private(set) var isOffloading = false
    private(set) var offloadProgress = DAMOffloadProgress()
    private(set) var offloadResult: DAMOffloadResult?
    private var offloadTask: Task<Void, Never>?

    private let database: DAMDatabase

    init(database: DAMDatabase = .shared) {
        self.database = database

        // Observe agent-driven filter updates from dam_filter_view tool.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplyFilters(_:)),
            name: .damApplyFilters,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .damApplyFilters, object: nil)
    }

    @objc private func handleApplyFilters(_ note: Notification) {
        let search = note.userInfo?["search"] as? String
        let tagColor = note.userInfo?["tag_color"] as? Int
        let fileType = note.userInfo?["file_type"] as? String
        let flag = note.userInfo?["flag"] as? String
        let minRating = note.userInfo?["min_rating"] as? Int
        let sort = note.userInfo?["sort"] as? String
        let folder = note.userInfo?["folder"] as? String
        let clear = note.userInfo?["clear"] as? Bool == true
        applyFilterState(
            search: search, tagColor: tagColor, fileType: fileType,
            flag: flag, minRating: minRating, sort: sort,
            folder: folder, clear: clear)
    }

    // MARK: - On-demand metadata enrichment

    /// Reads metadata for a single file immediately when selected.
    private func enrichIfNeeded(_ id: DAMAsset.ID) {
        guard let id, let asset = assets.first(where: { $0.id == id }) else { return }
        guard asset.fileSize == nil || asset.xattrKeywords == nil else { return }

        let path = asset.path
        Task.detached(priority: .userInitiated) { [database] in
            guard let updated = await DAMImportService.enrichSingleFile(
                path: path, database: database
            ) else { return }

            await MainActor.run { [weak self] in
                guard let self,
                      let index = self.assets.firstIndex(where: { $0.path == path }) else { return }
                self.assets[index] = updated
            }
        }
    }



    // MARK: - Background enrichment

    /// Starts a background enrichment pass for any cataloged assets
    /// still missing xattr tags, file size, or EXIF metadata. Runs
    /// automatically on browser appear and after each import.
    private(set) var isEnriching = false
    private(set) var enrichProgress = ""

    func startBackgroundEnrichment() {
        guard !isEnriching else { return }
        isEnriching = true
        enrichProgress = "Enriching metadata..."
        Task.detached(priority: .utility) {
            try? await DAMImportService.shared.enrichAll { enriched, total in
                Task { @MainActor [weak self] in
                    self?.enrichProgress = "Enriched \(enriched)/\(total)"
                }
            }
            await MainActor.run { [weak self] in
                self?.isEnriching = false
                self?.enrichProgress = ""
            }
            // Reload to pick up enriched metadata
            await self.reload()
            await self.refreshFolderTree()
        }
    }

    // MARK: - Loading

    /// Applies filter state from a `damApplyFilters` notification (posted by
    /// the `dam_filter_view` tool).  Only non-nil parameters are touched —
    /// everything else keeps its current value.
    private func applyFilterState(
        search: String?, tagColor: Int?, fileType: String?,
        flag: String?, minRating: Int?, sort: String?,
        folder: String?, clear: Bool
    ) {

        if clear {
            searchText = ""
            minimumRating = 0
            sortOrder = .captureDateDesc
            filterTagColor = nil
            filterFileType = nil
            filterTagged = nil
            filterFlag = nil
            selectedFolder = nil
            return  // reload() fires from the last didSet
        }

        if let search { searchText = search }  // triggers scheduleSearch()
        if let tagColor { filterTagColor = tagColor }
        if let fileType { filterFileType = fileType }
        if let flag { filterFlag = DAMFlag(rawValue: flag) }
        if let minRating { minimumRating = minRating }
        if let sort {
            sortOrder = DAMDatabase.DAMSortOrder(rawValue: sort)
                ?? Self.parseSortOrder(sort)
        }
        if let folder { selectedFolder = folder }
        // If only non-reload-triggering filters were set, fire an explicit reload.
        if search == nil {
            Task { await reload() }
        }
    }

    /// Maps user-friendly sort names to the enum when raw value init fails.
    private static func parseSortOrder(_ str: String) -> DAMDatabase.DAMSortOrder {
        switch str.lowercased() {
        case "capture_date", "date": return .captureDateDesc
        case "date_asc", "oldest": return .captureDateAsc
        case "filename", "name": return .filenameAsc
        case "size", "largest": return .sizeDesc
        case "rating", "stars": return .ratingDesc
        default: return .captureDateDesc
        }
    }

    /// Initial load / full refresh honoring current filters.
    func reload() async {
        do {
            if let collectionID = selectedCollectionID {
                let filtered = try await fetchCollectionAssets(collectionID: collectionID)
                assets = Array(filtered.prefix(pageSize))
                totalAssetCount = filtered.count
                canLoadMore = filtered.count > pageSize
                errorMessage = nil
                return
            }

            let folder = selectedFolder
            let rating = minimumRating
            let tagColor = filterTagColor
            let fileType = filterFileType
            let tagged = filterTagged
            let flag = filterFlag
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            async let page = fetchPage(offset: 0)
            async let count = Task.detached(priority: .userInitiated) { [database] in
                // Count must match the results path: plain browse counts with
                // filters; search counts with filters AND the query.
                if query.isEmpty {
                    return try database.assetCount(folder: folder, minRating: rating,
                                                   tagColor: tagColor, fileType: fileType,
                                                   tagged: tagged, flag: flag)
                }
                return try database.searchAssetCount(matching: query, folder: folder,
                                                     minRating: rating,
                                                     tagColor: tagColor, fileType: fileType,
                                                     tagged: tagged, flag: flag)
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
    ///
    /// The tree and volumes are built on a background thread and assigned as
    /// soon as possible. Finder tag colors are loaded asynchronously afterward
    /// so xattr/Spotlight work doesn't block the sidebar from appearing.
    func refreshFolderTree() async {
        do {
            let result = try await Task.detached(priority: .userInitiated) { [database] in
                let counts = try database.folderCounts()
                let tree = Self.buildTree(from: counts)
                let volumes = Self.buildVolumeNodes()
                let collections = try database.allCollections()
                let collectionCounts = try database.dbQueue.read { db in
                    try Row.fetchAll(db, sql: "SELECT collectionId, COUNT(*) AS n FROM collectionAsset GROUP BY collectionId")
                        .reduce(into: [Int64: Int]()) { dict, row in
                            let id: Int64 = row["collectionId"]
                            let count: Int = row["n"]
                            dict[id] = count
                        }
                }
                return (tree: tree, volumes: volumes, folders: counts.map(\.folder), collections: collections, collectionCounts: collectionCounts)
            }.value

            folderTree = result.tree
            volumeNodes = result.volumes
            collections = result.collections
            collectionAssetCounts = result.collectionCounts

            // Read Finder tag colors asynchronously so the tree is visible
            // immediately; colors will fill in when the xattr scan finishes.
            let folders = result.folders
            Task.detached(priority: .utility) { [weak self] in
                let colors = Self.readFolderTagColors(for: folders)
                await MainActor.run { [weak self] in
                    self?.folderTagColors = colors
                }
            }
        } catch {
            NSLog("[DAM] folder tree refresh failed: %@", String(describing: error))
        }
    }

    /// Reload just the collections list from the database.
    func refreshCollections() async {
        do {
            collections = try await Task.detached(priority: .userInitiated) { [database] in
                try database.allCollections()
            }.value
        } catch {
            errorMessage = "Failed to load collections: \(error.localizedDescription)"
        }
    }

    /// Create or update a collection.
    func saveCollection(id: Int64?, name: String, kind: DAMCollection.Kind, predicateJSON: String?, parentId: Int64? = nil) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if let id {
                try database.updateCollection(id: id, name: trimmed, kind: kind, predicateJSON: predicateJSON, parentId: parentId)
                if kind == .smart {
                    try database.applySmartCollection(id: id)
                }
            } else {
                let collection = try database.createCollection(name: trimmed, kind: kind, predicateJSON: predicateJSON, parentId: parentId)
                if kind == .smart, let newId = collection.id {
                    try database.applySmartCollection(id: newId)
                }
            }
            await refreshCollections()
        } catch {
            errorMessage = "Failed to save collection: \(error.localizedDescription)"
        }
    }

    /// Move a collection under a new parent (or top level).
    func setCollectionParent(id: Int64, parentId: Int64?) async {
        guard id != parentId ?? -1 else { return }
        do {
            try database.updateCollectionParent(id: id, parentId: parentId)
            await refreshCollections()
        } catch {
            errorMessage = "Failed to move collection: \(error.localizedDescription)"
        }
    }

    /// Physically move a catalog folder under a new parent folder and update
    /// every affected asset path. The folder tree and current selection are
    /// refreshed afterwards.
    func moveFolder(path: String, toParent parentPath: String) async {
        guard parentPath != path, !parentPath.hasPrefix(path + "/") else {
            errorMessage = "Cannot move a folder into itself or one of its descendants."
            return
        }
        do {
            let newPath = try database.moveFolder(from: path, toParent: parentPath)
            await refreshFolderTree()
            if selectedFolder == path { selectedFolder = newPath }
        } catch {
            errorMessage = "Failed to move folder: \(error.localizedDescription)"
        }
    }

    /// Delete a collection. Original assets are not affected.
    func deleteCollection(id: Int64) async {
        do {
            try database.deleteCollection(id: id)
            if selectedCollectionID == id { selectedCollectionID = nil }
            await refreshCollections()
        } catch {
            errorMessage = "Failed to delete collection: \(error.localizedDescription)"
        }
    }

    /// Add the current selection to a collection.
    func addSelectionToCollection(_ collectionId: Int64) async {
        let ids = Array(selection).compactMap { $0 }
        await addAssetIds(ids, to: collectionId)
    }

    /// Add a specific list of asset IDs to a collection.
    func addAssetIds(_ ids: [Int64], to collectionId: Int64) async {
        guard !ids.isEmpty else { return }
        do {
            try database.addAssetsToCollection(assetIds: ids, collectionId: collectionId)
            if selectedCollectionID == collectionId {
                await reload()
            }
            await refreshCollections()
        } catch {
            errorMessage = "Failed to add to collection: \(error.localizedDescription)"
        }
    }

    /// Remove the current selection from the active collection.
    func removeSelectionFromActiveCollection() async {
        guard let collectionId = selectedCollectionID else { return }
        let ids = Array(selection).compactMap { $0 }
        guard !ids.isEmpty else { return }
        do {
            try database.removeAssetsFromCollection(assetIds: ids, collectionId: collectionId)
            await reload()
            await refreshCollections()
        } catch {
            errorMessage = "Failed to remove from collection: \(error.localizedDescription)"
        }
    }

    /// Reads Finder tag color indices from folder xattrs. Returns a dict of
    /// folder path → array of color indices (for multi-tag rainbow dots).
    /// Runs on a background thread — safe to call from any context.
    nonisolated static func readFolderTagColors(
        for folders: [String]
    ) -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for folder in folders {
            let (_, colorsJSON) = DAMImportService.readXattrTags(
                at: URL(fileURLWithPath: folder)
            )
            guard let json = colorsJSON,
                  let data = json.data(using: .utf8),
                  let map = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
            else { continue }
            // Use cached consensus; fall back to inline Spotlight vote
            // when the cache hasn't been populated yet (first launch).
            var indices: [Int] = []
            let consensus = DAMImportService.cachedConsensus ?? [:]
            for (tag, color) in map {
                var resolved = consensus[tag] ?? color
                if consensus.isEmpty || consensus[tag] == nil {
                    if let vote = DAMImportService.diskWideColorVote(forTag: tag) {
                        resolved = vote
                    }
                }
                if resolved > 1 {
                    indices.append(resolved)
                }
            }
            if !indices.isEmpty {
                result[folder] = indices.sorted()
            }
        }
        return result
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
            // Aggregate the direct count with all descendants so every folder
            // in the sidebar shows the total assets under it, not just its leaf.
            let totalCount = node.count + children.reduce(0) { $0 + $1.count }
            return DAMFolderNode(
                path: path, name: name, count: totalCount,
                children: children.isEmpty ? nil : children)
        }
        return root.children.keys.sorted().compactMap { key in
            root.children[key].flatMap { convert(key, $0, path: "/" + key) }
        }
    }

    /// Builds the list of mounted local volumes for the Folders sidebar.
    /// Includes the root volume ("/") as "Macintosh HD" and any external
    /// volumes. System/synthetic volumes and APFS snapshots are excluded.
    nonisolated static func buildVolumeNodes() -> [DAMFolderNode] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: []
        ) else { return [] }

        var nodes: [DAMFolderNode] = []
        for url in urls {
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName)
                ?? url.lastPathComponent
            guard !damIsSnapshotVolume(name: name),
                  !damIsSystemOrSyntheticVolume(name: name, url: url)
            else { continue }

            let displayName: String
            let path = url.path
            if path == "/" {
                displayName = name.isEmpty ? "Macintosh HD" : name
            } else {
                displayName = name.isEmpty ? url.lastPathComponent : name
            }
            nodes.append(DAMFolderNode(
                path: path,
                name: displayName,
                count: 0,
                children: nil
            ))
        }

        // Root volume first, then alphabetical.
        nodes.sort {
            if $0.path == "/" { return true }
            if $1.path == "/" { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return nodes
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
        let tagColor = filterTagColor
        let fileType = filterFileType
        let tagged = filterTagged
        let flag = filterFlag
        return try await Task.detached(priority: .userInitiated) { [database] in
            if query.isEmpty {
                return try database.assets(
                    folder: folder, minRating: rating, sort: sort,
                    limit: limit, offset: offset,
                    tagColor: tagColor, fileType: fileType,
                    tagged: tagged, flag: flag)
            }
            // Search WITH the toolbar filters applied and real pagination —
            // the old path ignored both, so the count disagreed and "load
            // more" re-fetched page 1 forever.
            return try database.searchAssets(
                matching: query, folder: folder, minRating: rating,
                tagColor: tagColor, fileType: fileType,
                tagged: tagged, flag: flag,
                limit: limit, offset: offset)
        }.value
    }

    /// Loads and filters all assets in a collection in memory. Collections are
    /// typically much smaller than the whole catalog, so this keeps the UI
    /// consistent with the toolbar filters without needing a new SQL query path.
    private func fetchCollectionAssets(collectionID: Int64) async throws -> [DAMAsset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rating = minimumRating
        let tagColor = filterTagColor
        let fileType = filterFileType
        let tagged = filterTagged
        let flag = filterFlag
        let sort = sortOrder

        return try await Task.detached(priority: .userInitiated) { [database] in
            var assets = try database.assets(inCollectionId: collectionID)

            if !query.isEmpty {
                let lower = query.lowercased()
                assets = assets.filter { asset in
                    [asset.filename, asset.aiCaption, asset.aiKeywords, asset.ocrText, asset.xattrKeywords]
                        .compactMap { $0 }
                        .contains { $0.lowercased().contains(lower) }
                }
            }

            assets = assets.filter { $0.rating >= rating }

            if let tagColor {
                let mid = "%\":\(tagColor),%"
                let end = "%\":\(tagColor)}"
                assets = assets.filter { $0.tagColors?.contains(mid) == true || $0.tagColors?.contains(end) == true }
            }

            if let fileType {
                assets = assets.filter {
                    $0.kind == fileType || ($0.kind == nil && ($0.uti?.contains(fileType) ?? false))
                }
            }

            if let tagged {
                assets = assets.filter {
                    let hasTags = !($0.xattrKeywords?.isEmpty ?? true)
                    return tagged ? hasTags : !hasTags
                }
            }

            if let flag {
                assets = assets.filter { $0.flag == flag }
            }

            assets.sort { lhs, rhs in
                switch sort {
                case .captureDateDesc:
                    return (lhs.captureDate ?? .distantPast) > (rhs.captureDate ?? .distantPast)
                case .captureDateAsc:
                    return (lhs.captureDate ?? .distantFuture) < (rhs.captureDate ?? .distantFuture)
                case .filenameAsc:
                    return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
                case .sizeDesc:
                    return (lhs.fileSize ?? 0) > (rhs.fileSize ?? 0)
                case .ratingDesc:
                    return lhs.rating > rhs.rating
                }
            }

            return assets
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

        // Launch the import on a detached task so the MainActor stays free
        // to process progress callbacks. Awaiting task.value on the
        // MainActor suspends this method until completion without blocking
        // the actor, so UI updates interleave naturally.
        let task = Task.detached(priority: .userInitiated) { [database] in
            try await DAMImportService.shared.importFolder(at: url, database: database) {
                scanned, written in
                Task { @MainActor [weak self] in
                    self?.importScanned = scanned
                    self?.importWritten = written
                }
            }
        }
        importTask = task

        do {
            let count = try await task.value
            importScanned = count
            importWritten = count
        } catch is CancellationError {
            errorMessage = "Import cancelled."
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }

        isImporting = false
        importTask = nil

        await reload()
        await refreshFolderTree()

        // Background enrichment: read xattr tags for all cataloged files
        // that are missing them. Runs after the UI is responsive.
        Task.detached(priority: .utility) { [weak self] in
            try? await DAMImportService.shared.enrichAll { _, _ in
                // Optionally update a status indicator here
            }
            await MainActor.run { [weak self] in
                Task { await self?.reload() }
            }
        }
    }

    /// Cancel a running import. The next `Task.checkCancellation()` in the
    /// scan loop will throw and unwind the enumerator.
    func cancelImport() {
        importTask?.cancel()
    }

    // MARK: - Offload & ingest

    /// Start an offload: copy files from source to primary (and optional backup),
    /// verify with SHA-256, rename via templates, then import primary copies.
    func startOffload(options: DAMOffloadOptions) {
        guard !isOffloading, options.isValid else { return }
        isOffloading = true
        offloadProgress = DAMOffloadProgress()
        offloadResult = nil

        offloadTask = Task { [weak self] in
            guard let self else { return }
            let result = await DAMOffloadService.shared.offload(options: options, database: self.database) { progress in
                Task { @MainActor [weak self] in
                    self?.offloadProgress = progress
                }
            }
            await MainActor.run { [weak self] in
                self?.offloadResult = result
                self?.isOffloading = false
            }
            await self.reload()
            await self.refreshFolderTree()
        }
    }

    func cancelOffload() {
        offloadTask?.cancel()
    }

    // MARK: - Lightroom CSV import

    private(set) var isImportingLightroom = false
    private(set) var lightroomProgress = ""
    private(set) var lightroomSummary: String?
    private var lightroomTask: Task<Void, Never>?

    /// Two-panel flow: pick the CSV export, then the folder that CONTAINS
    /// the Lightroom top-level folders (CSV paths are catalog-relative).
    func importLightroomCSVWithPanel() {
        let csvPanel = NSOpenPanel()
        csvPanel.canChooseFiles = true
        csvPanel.canChooseDirectories = false
        csvPanel.allowsMultipleSelection = false
        csvPanel.allowedContentTypes = [.commaSeparatedText, .plainText]
        csvPanel.message = "Choose the Lightroom catalog CSV export"
        guard csvPanel.runModal() == .OK, let csvURL = csvPanel.url else { return }

        let rootPanel = NSOpenPanel()
        rootPanel.canChooseFiles = false
        rootPanel.canChooseDirectories = true
        rootPanel.allowsMultipleSelection = false
        rootPanel.message = "Choose the folder that CONTAINS the Lightroom folders (e.g. the parent of “Photos”)"
        rootPanel.prompt = "Use as Root"
        guard rootPanel.runModal() == .OK, let rootURL = rootPanel.url else { return }

        isImportingLightroom = true
        lightroomProgress = "Parsing CSV…"
        lightroomSummary = nil
        lightroomTask = Task {
            do {
                let result = try await DAMLightroomImporter.shared.importCSV(
                    at: csvURL, root: rootURL) { scanned, total in
                        Task { @MainActor [weak self] in
                            self?.lightroomProgress = "Importing \(scanned)/\(total)…"
                        }
                    }
                lightroomSummary = "Lightroom import: \(result.scanned) rows — "
                    + "\(result.inserted) new assets, \(result.updated) updated, "
                    + "\(result.keywordsApplied) keywords/labels tagged, "
                    + "\(result.collectionsCreated) collections created."
                    + (result.missingOnDisk > 0
                       ? " \(result.missingOnDisk) files not on disk (cataloged offline)."
                       : "")
                errorMessage = nil
            } catch is CancellationError {
                lightroomSummary = "Lightroom import cancelled."
            } catch {
                errorMessage = "Lightroom import failed: \(error.localizedDescription)"
            }
            isImportingLightroom = false
            lightroomProgress = ""
            await reload()
            await refreshFolderTree()
        }
    }

    func cancelLightroomImport() {
        lightroomTask?.cancel()
    }

    // MARK: - Direct .lrcat import

    private(set) var isImportingLrcat = false
    private(set) var lrcatProgress = ""
    private(set) var lrcatSummary: String?
    private var lrcatTask: Task<Void, Never>?

    /// Pick a .lrcat file and import it directly (no CSV export needed).
    func importLrcatWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "lrcat")!]
        panel.message = "Choose a Lightroom catalog (.lrcat) file"
        guard panel.runModal() == .OK, let lrcatURL = panel.url else { return }

        isImportingLrcat = true
        lrcatProgress = "Reading catalog…"
        lrcatSummary = nil
        lrcatTask = Task {
            do {
                let result = try await DAMLrcatReader.shared.importLrcat(
                    at: lrcatURL) { scanned, total in
                        Task { @MainActor [weak self] in
                            self?.lrcatProgress = "Importing \(scanned)/\(total)…"
                        }
                    }
                lrcatSummary = "Lightroom catalog: \(result.scanned) images — "
                    + "\(result.inserted) new assets, \(result.updated) updated, "
                    + "\(result.keywordsApplied) keywords applied, "
                    + "\(result.collectionsCreated) collections created."
                    + (result.missingOnDisk > 0
                       ? " \(result.missingOnDisk) files not on disk (cataloged offline)."
                       : "")
                errorMessage = nil
            } catch is CancellationError {
                lrcatSummary = "Lightroom catalog import cancelled."
            } catch {
                errorMessage = "Lightroom catalog import failed: \(error.localizedDescription)"
            }
            isImportingLrcat = false
            lrcatProgress = ""
            await reload()
            await refreshFolderTree()
        }
    }

    func cancelLrcatImport() {
        lrcatTask?.cancel()
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

    // MARK: - Generative AI tagging

    /// True for catalog rows that support AI tagging: images (vision proxy)
    /// and audio (WhisperKit transcription + NLP keyword extraction).
    private static func isTaggableAsset(_ asset: DAMAsset) -> Bool {
        let url = URL(fileURLWithPath: asset.path)
        return DAMFileKind.isStandardImage(url)
            || DAMFileKind.isCameraRAW(url)
            || DAMFileKind.isAudio(url)
            || DAMFileKind.isVideo(url)
    }

    /// Generate AI tags for the current selection. Unsupported assets are
    /// ignored; images go to the vision proxy and audio goes to WhisperKit.
    func generateTags(for ids: Set<DAMAsset.ID>) async {
        let assets = await assets(for: ids)
        let taggable = assets.filter(Self.isTaggableAsset)
        guard !taggable.isEmpty else {
            errorMessage = "No image, audio, or video assets selected."
            return
        }
        errorMessage = "Generating tags for \(taggable.count) asset(s)…"
        do {
            _ = try await DAMTaggingService.shared.generateTags(for: taggable) { _ in }
            errorMessage = "Tag generation complete."
            await reload()
        } catch is CancellationError {
            errorMessage = "Tag generation cancelled."
        } catch {
            errorMessage = "Tag generation failed: \(error.localizedDescription)"
        }
    }

    /// Generate AI tags for every image/audio asset in the selected folder.
    func generateTagsForSelectedFolder() async {
        guard let folder = selectedFolder else {
            errorMessage = "No folder selected."
            return
        }
        await generateTagsForFolder(folder)
    }

    /// Generate AI tags for every image/audio asset in a specific folder.
    func generateTagsForFolder(_ folder: String) async {
        do {
            let assets = try database.assets(inFolder: folder, recursive: true)
            let taggable = assets.filter(Self.isTaggableAsset)
            guard !taggable.isEmpty else {
                errorMessage = "No image or audio assets found in \(folder)."
                return
            }
            errorMessage = "Generating tags for \(taggable.count) asset(s) in folder…"
            _ = try await DAMTaggingService.shared.generateTags(for: taggable) { _ in }
            errorMessage = "Tag generation complete for \(folder)."
            await reload()
        } catch is CancellationError {
            errorMessage = "Tag generation cancelled."
        } catch {
            errorMessage = "Tag generation failed: \(error.localizedDescription)"
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

    // MARK: - Export

    /// One row in the export processing queue.
    struct ExportQueueItem: Identifiable, Equatable, Sendable {
        let id = UUID()
        let filename: String
        var state: DAMExportService.ItemState
    }

    private(set) var isExporting = false
    private(set) var exportProgressDone = 0
    private(set) var exportProgressTotal = 0
    private(set) var exportCurrentFile = ""
    private(set) var lastExportResult: DAMExportService.ExportResult?
    /// The live processing queue shown in the Output workspace while an
    /// export runs — one row per selected asset, updated per item.
    private(set) var exportQueue: [ExportQueueItem] = []
    private var exportTask: Task<Void, Never>?

    /// Export the current selection with a full preset (format, sizing,
    /// quality, metadata policy, watermark, destination all bundled). The
    /// heavy decode/copy work runs in `DAMExportService` (nonisolated);
    /// progress + per-item states hop back to MainActor.
    func exportSelection(preset: DAMExportPreset) {
        guard !isExporting, !selection.isEmpty else { return }
        isExporting = true
        exportProgressDone = 0
        exportCurrentFile = ""
        lastExportResult = nil
        let destination = URL(fileURLWithPath: preset.destinationPath, isDirectory: true)

        exportTask = Task {
            let assets = await assets(for: selection)
            exportProgressTotal = assets.count
            exportQueue = assets.map { ExportQueueItem(filename: $0.filename, state: .pending) }
            let result = await DAMExportService.export(
                assets: assets, preset: preset, destination: destination,
                progress: { [weak self] done, total, name in
                    Task { @MainActor [weak self] in
                        self?.exportProgressDone = done
                        self?.exportProgressTotal = total
                        self?.exportCurrentFile = name
                    }
                },
                itemState: { [weak self] index, state in
                    Task { @MainActor [weak self] in
                        guard let self, self.exportQueue.indices.contains(index) else { return }
                        self.exportQueue[index].state = state
                    }
                })
            // On cancellation, everything still pending/processing reads as
            // skipped so the queue doesn't lie about what made it to disk.
            if result.cancelled {
                for index in exportQueue.indices
                where exportQueue[index].state == .pending
                    || exportQueue[index].state == .processing {
                    exportQueue[index].state = .skipped("Cancelled")
                }
            }
            lastExportResult = result
            isExporting = false
        }
    }

    /// Cancel the running export — the service loop stops between items.
    func cancelExport() {
        exportTask?.cancel()
    }
}
