import Foundation
import SwiftUI

// MARK: - Notes view model

/// View model for the SwiftMaestro Notes module.
/// Manages the vault folder, note tree, selection, and editor state.
@Observable
@MainActor
final class NotesViewModel {

    /// User-configurable vault path. Default is `~/Documents/SwiftMaestro Notes/`.
    var vaultURL: URL {
        didSet {
            if oldValue.path != vaultURL.path {
                UserDefaults.standard.set(vaultURL.path, forKey: NotesViewModel.vaultPathKey)
                Task { await load() }
            }
        }
    }

    /// Whether the vault is synced to iCloud Drive.
    var isCloudSyncEnabled: Bool = NotesiCloudSupport.isEnabled

    /// Short status message for the iCloud sync state (e.g. "Synced", "Uploading").
    var cloudSyncStatus: String = ""

    /// Root items of the vault folder tree.
    private(set) var rootItems: [NoteItem] = []

    /// Currently selected folder or note.
    var selectedItem: NoteItem? = nil {
        didSet { Task { await loadSelectedNote() } }
    }

    /// Text being edited in the editor.
    var editorText = ""

    /// Whether the current note has unsaved changes.
    var isDirty = false

    /// Whether a save is in flight (drives the "Saving…" toolbar state).
    private(set) var isSaving = false

    /// Whether edits are written back automatically after a short pause.
    /// Persisted; defaults to ON. Toggle lives in the editor toolbar.
    var autosaveEnabled: Bool {
        get { UserDefaults.standard.object(forKey: NotesViewModel.autosaveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: NotesViewModel.autosaveKey) }
    }

    /// Pending debounced autosave (cancelled on each new keystroke).
    private var autosaveTask: Task<Void, Never>?

    /// Set before programmatic editorText changes (note load/clear) so the
    /// resulting onChange doesn't count as a user edit and trigger autosave.
    private var suppressDirtyOnce = false

    /// Current search query.
    var searchQuery = "" {
        didSet { Task { await performSearch() } }
    }

    /// Search results when `searchQuery` is non-empty.
    private(set) var searchResults: [NoteItem] = []

    /// Last error message surfaced to the UI.
    private(set) var errorMessage: String?

    private var service: NotesService

    /// Exposed so other stores (e.g. `ChatCompaction`, which archives superseded
    /// summaries into the vault) can resolve the current vault path without
    /// needing a `NotesViewModel` instance injected.
    nonisolated static let vaultPathKey = "notes.vaultPath"
    nonisolated static let autosaveKey = "notes.autosaveEnabled"
    private nonisolated static let defaultVaultName = "notes"

    init() {
        let url = Self.resolveVaultURL()
        self.vaultURL = url
        self.service = NotesService(vaultURL: url)
        self.isCloudSyncEnabled = NotesiCloudSupport.isEnabled

        setupDefaultsChangeListener()

        // Reload the vault tree when another panel writes a note externally —
        // the Web Clipper saves clipped pages straight into the vault, and the
        // Notes panel must reflect them without a manual refresh.
        NotificationCenter.default.addObserver(
            forName: .notesVaultContentChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.load() }
        }

        // One-time migration: move the old app-support notes vault into Documents.
        Task {
            Self.migrateFromAppSupportIfNeeded(to: url)
        }
    }

    /// Re-evaluates the vault URL based on user settings or default local Documents location.
    static func resolveVaultURL() -> URL {
        let savedPath = UserDefaults.standard.string(forKey: NotesViewModel.vaultPathKey)
        if let savedPath, !savedPath.isEmpty {
            return URL(fileURLWithPath: savedPath)
        }
        if NotesiCloudSupport.isEnabled, let iCloudURL = NotesiCloudSupport.iCloudVaultURL {
            return iCloudURL
        }
        return NotesiCloudSupport.localVaultURL
    }

    /// Recalculate the vault URL if the user changes the iCloud default via the
    /// onboarding sheet and no explicit saved path exists yet.
    private func setupDefaultsChangeListener() {
        NotificationCenter.default.addObserver(
            forName: .notesVaultDefaultsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let savedPath = UserDefaults.standard.string(forKey: NotesViewModel.vaultPathKey)
            guard savedPath == nil || savedPath?.isEmpty == true else { return }
            Task { @MainActor in
                let newURL = Self.resolveVaultURL()
                if self.vaultURL.path != newURL.path {
                    self.vaultURL = newURL
                    self.service = NotesService(vaultURL: newURL)
                    self.isCloudSyncEnabled = NotesiCloudSupport.isEnabled
                    await self.load()
                }
            }
        }
    }

    /// Initial load of the vault tree, injecting the AI Memory folder into the root items.
    func load() async {
        do {
            try await service.ensureVault()
            var items = try await service.listDirectory(at: vaultURL)
            
            // Append permanent AI Memory folder link pointing to the shared
            // memory store (iCloud or ~/.ai-context/memory). Listed SHALLOWLY
            // (two levels) and tolerantly so the ~43K-file store is never
            // eagerly expanded into the tree and one unreadable subfolder can't
            // make the whole AI Memory entry disappear.
            if let memoryRoot = memoryRootURL {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: memoryRoot.path),
                   let memoryChildren = Self.makeShallowMemoryTree(root: memoryRoot) {
                    var aiMemoryItem = NoteItem(
                        url: memoryRoot,
                        isFolder: true,
                        modifiedAt: Date(),
                        children: memoryChildren
                    )
                    aiMemoryItem.isReadOnly = true
                    items.insert(aiMemoryItem, at: 0)
                } else if fileManager.fileExists(atPath: memoryRoot.path) {
                    // Memory root exists but couldn't be listed (macOS Full Disk
                    // Access / iCloud not readable yet). Show a single explanatory
                    // leaf rather than an expandable-but-empty node, so the user
                    // knows why no contents appear. The message rides in the
                    // filename because `NoteItem.title` is derived from it.
                    var placeholder = NoteItem(
                        url: memoryRoot.appendingPathComponent(
                            "contents-not-readable-grant-full-disk-access-relaunch.txt"),
                        isFolder: false,
                        modifiedAt: Date()
                    )
                    placeholder.isReadOnly = true
                    var aiMemoryItem = NoteItem(
                        url: memoryRoot,
                        isFolder: true,
                        modifiedAt: Date(),
                        children: [placeholder]
                    )
                    aiMemoryItem.isReadOnly = true
                    items.insert(aiMemoryItem, at: 0)
                }
            }

            rootItems = items
            errorMessage = nil
        } catch {
            errorMessage = "Could not load notes vault: \(error.localizedDescription)"
            NSLog("[NOTES] load failed: \(error)")
        }
    }

    /// Select a note and load its contents into the editor.
    /// Non-markdown assets (clip html/json/images) render in NoteAssetViewer
    /// instead — never route binary files through the text editor.
    func loadSelectedNote() async {
        autosaveTask?.cancel()
        guard let item = selectedItem, item.isNote else {
            suppressDirtyOnce = true
            editorText = ""
            isDirty = false
            return
        }
        do {
            suppressDirtyOnce = true
            editorText = try await service.readFile(at: item.url)
            isDirty = false
            errorMessage = nil
        } catch {
            errorMessage = "Could not read note: \(error.localizedDescription)"
            NSLog("[NOTES] read failed: \(error)")
        }
    }

    /// Save the current editor text back to the selected note.
    func saveCurrentNote() async {
        autosaveTask?.cancel()
        guard let item = selectedItem, item.isNote else { return }
        if let reason = readOnlyGuard(for: item, action: .write) {
            errorMessage = reason
            NSLog("[NOTES] blocked save to read-only AI Memory file: \(item.url.path)")
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.writeFile(at: item.url, content: editorText)
            isDirty = false
            errorMessage = nil
            await load() // Refresh modification dates
        } catch {
            errorMessage = "Could not save note: \(error.localizedDescription)"
            NSLog("[NOTES] save failed: \(error)")
        }
    }

    /// Create a new note in the currently selected folder (or vault root).
    func createNote(named name: String) async {
        let folder = selectedFolder()
        if let item = selectedItem, let reason = readOnlyGuard(for: item, action: .write), item.isFolder {
            errorMessage = reason
            return
        }
        do {
            let url = try await service.createNote(named: name, in: folder)
            await load()
            selectedItem = NoteItem(url: url, isFolder: false, modifiedAt: Date())
        } catch {
            errorMessage = "Could not create note: \(error.localizedDescription)"
            NSLog("[NOTES] create note failed: \(error)")
        }
    }

    /// Create a new folder in the currently selected folder (or vault root).
    func createFolder(named name: String) async {
        let folder = selectedFolder()
        if let item = selectedItem, let reason = readOnlyGuard(for: item, action: .write), item.isFolder {
            errorMessage = reason
            return
        }
        do {
            let url = try await service.createFolder(named: name, in: folder)
            await load()
            selectedItem = NoteItem(url: url, isFolder: true, modifiedAt: Date())
        } catch {
            errorMessage = "Could not create folder: \(error.localizedDescription)"
            NSLog("[NOTES] create folder failed: \(error)")
        }
    }

    /// Delete a note or folder.
    func delete(item: NoteItem) async {
        if let reason = readOnlyGuard(for: item, action: .delete) {
            errorMessage = reason
            return
        }
        if selectedItem?.id == item.id { selectedItem = nil }
        do {
            try await service.delete(item: item)
            await load()
        } catch {
            errorMessage = "Could not delete item: \(error.localizedDescription)"
            NSLog("[NOTES] delete failed: \(error)")
        }
    }

    /// Rename a note or folder.
    func rename(item: NoteItem, to name: String) async {
        if let reason = readOnlyGuard(for: item, action: .rename) {
            errorMessage = reason
            return
        }
        do {
            let newURL = try await service.rename(item: item, to: name)
            let isFolder = item.isFolder
            let newItem = NoteItem(url: newURL, isFolder: isFolder, modifiedAt: Date())
            if selectedItem?.id == item.id { selectedItem = newItem }
            await load()
        } catch {
            errorMessage = "Could not rename item: \(error.localizedDescription)"
            NSLog("[NOTES] rename failed: \(error)")
        }
    }

    /// Choose a different vault folder via the file picker.
    func chooseVaultFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        panel.message = "Select the folder that will hold your SwiftMaestro notes"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self.vaultURL = url
            }
        }
        #endif
    }

    /// Reset the vault to the default local Documents location.
    func resetVaultToDefault() {
        vaultURL = NotesiCloudSupport.localVaultURL
    }

    /// Enable or disable iCloud Drive sync for the notes vault.
    /// This backs up the current vault, moves it to/from iCloud Drive, and updates
    /// the active vault URL.
    func toggleCloudSync() async {
        let enabling = !isCloudSyncEnabled

        if enabling {
            guard let iCloudURL = NotesiCloudSupport.iCloudVaultURL else {
                errorMessage = "iCloud Drive is not available on this Mac."
                return
            }
            do {
                let backup = try NotesiCloudSupport.backupVault(at: vaultURL)
                try NotesiCloudSupport.moveVault(from: vaultURL, to: iCloudURL, force: false)
                NotesiCloudSupport.isEnabled = true
                isCloudSyncEnabled = true
                vaultURL = iCloudURL
                cloudSyncStatus = "iCloud sync enabled"
                NSLog("[NOTES] Enabled iCloud sync. Backup: \(backup.path)")
            } catch {
                errorMessage = "Could not move notes to iCloud Drive: \(error.localizedDescription)"
                NSLog("[NOTES] iCloud enable failed: \(error)")
            }
        } else {
            let localURL = NotesiCloudSupport.localVaultURL
            do {
                let backup = try NotesiCloudSupport.backupVault(at: vaultURL)
                try NotesiCloudSupport.moveVault(from: vaultURL, to: localURL, force: true)
                NotesiCloudSupport.isEnabled = false
                isCloudSyncEnabled = false
                vaultURL = localURL
                cloudSyncStatus = "Local vault"
                NSLog("[NOTES] Disabled iCloud sync. Backup: \(backup.path)")
            } catch {
                errorMessage = "Could not move notes back to Documents: \(error.localizedDescription)"
                NSLog("[NOTES] iCloud disable failed: \(error)")
            }
        }

        await load()
    }

    /// Move any notes left in the old app-support vault into the new Documents vault.
    /// This is idempotent: once the old folder is empty or missing, it does nothing.
    private nonisolated static func migrateFromAppSupportIfNeeded(to localVault: URL) {
        let fm = FileManager.default
        let oldVault = SwiftMaestroPaths.dataDir.appendingPathComponent(
            NotesViewModel.defaultVaultName, isDirectory: true)
        guard fm.fileExists(atPath: oldVault.path),
              !fm.fileExists(atPath: localVault.path) else { return }

        do {
            try NotesiCloudSupport.moveVault(from: oldVault, to: localVault)
            NSLog("[NOTES] Migrated notes vault from app support to Documents: \(localVault.path)")
        } catch {
            NSLog("[NOTES] Failed to migrate notes vault from app support: \(error)")
        }
    }

    /// Mark the editor as dirty when the user types.
    func markDirty() {
        // Programmatic loads (note switch/clear) flow through the same
        // onChange — swallow exactly one of those per load.
        if suppressDirtyOnce {
            suppressDirtyOnce = false
            return
        }
        isDirty = true
        scheduleAutosave()
    }

    // MARK: - Autosave

    /// Debounced write-back: saves 1.5s after the user stops typing.
    /// Cancelled by further edits, note switches, and manual saves.
    private func scheduleAutosave() {
        guard autosaveEnabled else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            await saveCurrentNote()
        }
    }

    // MARK: - Private

    private func selectedFolder() -> URL {
        guard let item = selectedItem else { return vaultURL }
        return item.isFolder ? item.url : item.url.deletingLastPathComponent()
    }

    /// Build a bounded, tolerant, read-only listing of the AI Memory root so the
    /// huge shared store (tens of thousands of files) is never eagerly expanded
    /// into the Notes tree, and a single unreadable subfolder can't hide the whole
    /// entry. Traverses a few levels so subfolders are actually expandable, but
    /// stops at a hard node cap to bound memory. Folders with no discovered
    /// children are emitted with `children == nil` so SwiftUI renders them as true
    /// leaves (a non-nil-but-empty array would suppress the disclosure chevron).
    /// Returns nil only if the root itself fails to read.
    private static func makeShallowMemoryTree(root: URL) -> [NoteItem]? {
        let maxDepth = 4
        let maxNodes = 600
        var nodeCount = 0

        func scan(_ folder: URL, depth: Int) -> [NoteItem] {
            let fm = FileManager.default
            let contents = (try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            var items: [NoteItem] = []
            for url in contents {
                if nodeCount >= maxNodes { break }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                if isDir {
                    // Deeper folders stay folded once we hit the depth budget or
                    // node cap; deeper than that always reads lazily on expansion.
                    let children = depth <= 0 ? nil : scan(url, depth: depth - 1)
                    var item = NoteItem(url: url, isFolder: true, modifiedAt: modified, children: children)
                    // Only load-bearing structure (kind folders directly under the
                    // root) is read-only; nested content is user-editable.
                    item.isReadOnly = Self.isStructuralMemoryNode(url, root: root)
                    items.append(item)
                    nodeCount += 1
                } else if Self.isListableMemoryFile(url) {
                    var item = NoteItem(url: url, isFolder: false, modifiedAt: modified)
                    // Root index files (README/_index/*.json/*.md) are structural;
                    // notes nested inside a kind folder are freely editable.
                    item.isReadOnly = Self.isStructuralMemoryNode(url, root: root)
                    items.append(item)
                    nodeCount += 1
                }
            }
            // Folders with no descendants become true leaves (children == nil) so
            // SwiftUI shows no chevron instead of an expandable-but-empty one.
            return items.isEmpty ? items
                : items.sorted {
                    if $0.isFolder != $1.isFolder { return $0.isFolder && !$1.isFolder }
                    return $0.name.localizedCompare($1.name) == .orderedAscending
                }
        }

        // If the root itself can't even be listed, report that back to the caller
        // so `load()` can surface a clear explanation instead of an empty expand.
        guard let rootContents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]),
            !rootContents.isEmpty else {
            return nil
        }
        return scan(root, depth: maxDepth)
    }

    /// File types surfaced in the read-only AI Memory tree (markdown notes plus
    /// the plain-text knowledge files agents write). Internal artifacts
    /// (index DB, binary assets, iCloud .icloud placeholders) are excluded.
    private static func isListableMemoryFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "md", "txt", "markdown": return true
        default: return false
        }
    }

    /// The kind of mutation being attempted, so memory content edits are allowed
    /// while structure-breaking ones are blocked.
    enum MemoryEditAction {
        /// Saving content, or creating a note/folder (additive and safe).
        case write
        case delete
        case rename
    }

    /// True if the item lives inside the shared AI Memory store.
    func isInMemory(_ item: NoteItem) -> Bool {
        guard let memoryRoot = memoryRootURL else { return false }
        return item.url.path == memoryRoot.path || item.url.path.hasPrefix(memoryRoot.path + "/")
    }

    /// True if the item is a load-bearing part of the memory store that must not
    /// be deleted or renamed: the memory root itself, any top-level kind
    /// directory (e.g. `knowledge/`, `context/`), or any root index file
    /// (README, `_index.md`, `*.json`/`*.md` at the store root). Content nested
    /// inside a kind directory is freely editable.
    static func isStructuralMemoryNode(_ url: URL, root: URL) -> Bool {
        let rootPath = root.path
        let path = url.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        // The memory root itself is structural.
        if path == rootPath { return true }
        // Direct children of the root are the kind dirs + root index files.
        return url.deletingLastPathComponent().path == rootPath
    }

    /// The resolved shared AI Memory root (iCloud container or ~/.ai-context/memory).
    ///
    /// The on-disk store at `~/.ai-context/memory` is a SYMLINK into the iCloud
    /// container (e.g. `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/
    /// SwiftMaestro/memory`). The URL-based FileManager APIs used to build the
    /// memory tree (`contentsOfDirectory(at:includingPropertiesForKeys:)`) do NOT
    /// follow a top-level symlink and throw `ENOTDIR` ("Not a directory") on it,
    /// which made the memory tree show the "not readable — grant Full Disk Access"
    /// placeholder even when Full Disk Access was granted. Resolving the symlink
    /// yields the canonical on-disk directory those APIs can enumerate, so the
    /// real memory contents are listed. `resolvingSymlinksInPath()` is a no-op
    /// when the path is a real directory.
    private var memoryRootURL: URL? {
        let fm = FileManager.default
        if let iCloudContainer = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/SwiftMaestro/memory", isDirectory: true) {
            return iCloudContainer.resolvingSymlinksInPath()
        }
        let homeMemory = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".ai-context/memory", isDirectory: true)
        return homeMemory.resolvingSymlinksInPath()
    }

    /// Returns an error message when the requested mutation would break the AI
    /// Memory store. Users may freely edit content (save) and create notes or
    /// folders anywhere in memory, and may delete/rename content nested inside a
    /// kind folder. They may NOT delete or rename the memory root, top-level kind
    /// directories, or root index files — those keep the store working.
    func readOnlyGuard(for item: NoteItem?, action: MemoryEditAction) -> String? {
        guard let item, isInMemory(item) else { return nil }
        switch action {
        case .write:
            // Writing/creating memory content is additive — always allowed.
            return nil
        case .delete, .rename:
            guard let memoryRoot = memoryRootURL else { return nil }
            if Self.isStructuralMemoryNode(item.url, root: memoryRoot) {
                return "This is part of the AI Memory store's structure (a kind folder or index "
                    + "file). Deleting or renaming it would break memory for every agent. You can "
                    + "edit its contents freely, but don't delete or rename this item."
            }
            return nil
        }
    }


    private func performSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        do {
            searchResults = try await service.search(query: query)
        } catch {
            searchResults = []
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }
}

extension Notification.Name {
    /// Posted after an external writer (e.g. the Web Clipper) adds or modifies
    /// files in the Notes vault, so open Notes panels reload the tree.
    static let notesVaultContentChanged = Notification.Name("notesVaultContentChanged")
}
