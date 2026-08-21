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

    /// Re-evaluates the vault URL based on the current iCloud default.
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

    /// Initial load of the vault tree.
    func load() async {
        do {
            try await service.ensureVault()
            rootItems = try await service.listDirectory(at: vaultURL)
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
