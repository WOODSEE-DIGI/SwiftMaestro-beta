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

    private let database: DAMDatabase

    init(database: DAMDatabase = .shared) {
        self.database = database

        // Observe agent-driven filter updates from dam_filter_view tool.
        NotificationCenter.default.addObserver(
            forName: .damApplyFilters, object: nil, queue: .main
        ) { [weak self] note in
            // Extract values immediately on the nonisolated callback to avoid
            // Sendable issues with the raw userInfo dictionary.
            let search = note.userInfo?["search"] as? String
            let tagColor = note.userInfo?["tag_color"] as? Int
            let fileType = note.userInfo?["file_type"] as? String
            let flag = note.userInfo?["flag"] as? String
            let minRating = note.userInfo?["min_rating"] as? Int
            let sort = note.userInfo?["sort"] as? String
            let folder = note.userInfo?["folder"] as? String
            let clear = note.userInfo?["clear"] as? Bool == true
            Task { @MainActor [weak self] in
                self?.applyFilterState(
                    search: search, tagColor: tagColor, fileType: fileType,
                    flag: flag, minRating: minRating, sort: sort,
                    folder: folder, clear: clear)
            }
        }
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
    /// Also reads xattr Finder tag colors for each folder path.
    func refreshFolderTree() async {
        do {
            let counts = try await Task.detached(priority: .userInitiated) { [database] in
                try database.folderCounts()
            }.value
            folderTree = Self.buildTree(from: counts)

            // Read Finder tag colors for each folder (xattr on directories)
            let folders = counts.map(\.folder)
            let colors = await Task.detached(priority: .utility) {
                Self.readFolderTagColors(for: folders)
            }.value
            folderTagColors = colors
        } catch {
            NSLog("[DAM] folder tree refresh failed: %@", String(describing: error))
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

        // Launch the import on a detached task. The progress callback
        // hops to @MainActor to update the UI counters. We use
        // withCheckedContinuation so the MainActor stays free to process
        // the progress callback Tasks during the scan.
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

        await withCheckedContinuation { continuation in
            Task.detached {
                let result: Result<Int, Error>
                do {
                    let count = try await task.value
                    result = .success(count)
                } catch {
                    result = .failure(error)
                }
                await MainActor.run {
                    switch result {
                    case .success(let written):
                        self.importScanned = written
                        self.importWritten = written
                    case .failure(let error) where error is CancellationError:
                        self.errorMessage = "Import cancelled."
                    case .failure(let error):
                        self.errorMessage = "Import failed: \(error.localizedDescription)"
                    }
                    self.isImporting = false
                    self.importTask = nil
                    continuation.resume()
                }
            }
        }

        await reload()
        await refreshFolderTree()

        // Background enrichment: read xattr tags for all cataloged files
        // that are missing them. Runs after the UI is responsive.
        Task.detached(priority: .utility) {
            try? await DAMImportService.shared.enrichAll { enriched, total in
                // Optionally update a status indicator here
            }
            await MainActor.run {
                Task { await self.reload() }
            }
        }
    }

    /// Cancel a running import. The next `Task.checkCancellation()` in the
    /// scan loop will throw and unwind the enumerator.
    func cancelImport() {
        importTask?.cancel()
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
