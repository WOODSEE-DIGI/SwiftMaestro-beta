import SwiftUI

// MARK: - Workspace Layout Preset

/// A named snapshot of the workspace canvas layout. Captures which panels are
/// open, where they sit on the grid, and which are floating — so the user can
/// save, recall, and share layout configurations.
struct WorkspaceLayoutPreset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// The numbered slot (1–10) this preset occupies in the workspace switcher.
    /// Nil if unassigned (legacy presets before slots were introduced).
    var slot: Int?
    var createdAt: Date
    var updatedAt: Date

    /// The canvas tiles at save time (grid positions, sizes, z-order).
    var canvasTiles: [CanvasTile]
    /// Panels that were floating in their own windows.
    var floatingPanels: [WorkspacePanelKind]
    /// Saved window frames (`WorkspacePanelKind.storageKey` → frame) for the
    /// panels in this layout — what makes a recall reposition windows on the
    /// right display instead of only re-tiling the canvas. Empty for the
    /// built-in presets, which predate frame storage.
    var windowFrames: [String: StoredFrame]
    /// Whether the workspace was locked.
    var isLocked: Bool

    /// Built-in presets ship with the app and cannot be deleted.
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        slot: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        canvasTiles: [CanvasTile],
        floatingPanels: [WorkspacePanelKind],
        windowFrames: [String: StoredFrame] = [:],
        isLocked: Bool,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.slot = slot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.canvasTiles = canvasTiles
        self.floatingPanels = floatingPanels
        self.windowFrames = windowFrames
        self.isLocked = isLocked
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slot, createdAt, updatedAt
        case canvasTiles, floatingPanels, windowFrames, isLocked, isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Layout"
        slot = try container.decodeIfPresent(Int.self, forKey: .slot)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        canvasTiles = try container.decodeIfPresent([CanvasTile].self, forKey: .canvasTiles) ?? []
        floatingPanels = try container.decodeIfPresent([WorkspacePanelKind].self, forKey: .floatingPanels) ?? []
        windowFrames = try container.decodeIfPresent([String: StoredFrame].self, forKey: .windowFrames) ?? [:]
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(slot, forKey: .slot)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(canvasTiles, forKey: .canvasTiles)
        try container.encode(floatingPanels, forKey: .floatingPanels)
        try container.encode(windowFrames, forKey: .windowFrames)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
    }
}

// MARK: - Workspace Layout Preset Store

/// Manages saved workspace layout presets: save the current layout, recall a
/// saved preset, rename/delete user presets, and provide built-in defaults.
@Observable
@MainActor
final class WorkspaceLayoutPresetStore {

    static let shared = WorkspaceLayoutPresetStore()

    /// All saved presets (built-in + user), ordered by creation date.
    private(set) var presets: [WorkspaceLayoutPreset] = []

    /// The ID of the currently active preset (if any). Set when the user
    /// recalls a preset; nil when the layout has been modified since recall.
    var activePresetID: UUID?

    private let defaultsKey = "SwiftMaestro.LayoutPresets"
    private var gridVersionKey: String { defaultsKey + ".gridVersion" }
    private let currentGridVersion = 2
    private let layout = WorkspaceLayoutState.shared

    init() {
        load()
        ensureBuiltInPresets()
    }

    // MARK: - Save

    /// Save the current workspace layout as a new preset.
    @discardableResult
    func saveCurrentLayout(as name: String) -> WorkspaceLayoutPreset {
        var preset = WorkspaceLayoutPreset(
            name: name,
            canvasTiles: layout.canvasTiles,
            floatingPanels: Array(layout.floatingPanels),
            windowFrames: currentWindowFrames(),
            isLocked: layout.isLocked
        )
        // Assign built-in status if this matches a known default.
        if BuiltInPreset.allCases.contains(where: { $0.displayName == name }) {
            preset.isBuiltIn = true
        }
        presets.append(preset)
        activePresetID = preset.id
        save()
        return preset
    }

    /// Save the current workspace layout to a specific numbered slot (1–10).
    /// If a preset already occupies that slot, it is overwritten.
    @discardableResult
    func saveToSlot(_ slot: Int, name: String? = nil) -> WorkspaceLayoutPreset {
        let resolvedName = name ?? "Layout \(slot)"
        // Remove any existing preset in this slot.
        if let existing = presets.first(where: { $0.slot == slot }) {
            presets.removeAll { $0.id == existing.id }
        }
        var preset = WorkspaceLayoutPreset(
            name: resolvedName,
            slot: slot,
            canvasTiles: layout.canvasTiles,
            floatingPanels: Array(layout.floatingPanels),
            windowFrames: currentWindowFrames(),
            isLocked: layout.isLocked
        )
        // Assign built-in status if this matches a known default.
        if BuiltInPreset.allCases.contains(where: { $0.displayName == resolvedName }) {
            preset.isBuiltIn = true
        }
        presets.append(preset)
        activePresetID = preset.id
        save()
        return preset
    }

    /// Look up the preset assigned to a numbered slot (1–10).
    func preset(forSlot slot: Int) -> WorkspaceLayoutPreset? {
        presets.first(where: { $0.slot == slot })
    }

    /// Overwrite an existing preset with the current layout.
    func updatePreset(_ id: UUID) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].canvasTiles = layout.canvasTiles
        presets[idx].floatingPanels = Array(layout.floatingPanels)
        presets[idx].windowFrames = currentWindowFrames()
        presets[idx].isLocked = layout.isLocked
        presets[idx].updatedAt = Date()
        activePresetID = id
        save()
    }

    // MARK: - Recall

    /// Apply a saved preset to the workspace, replacing the current layout.
    func recall(_ id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        layout.restorePreset(preset)
        // Reposition any open panel windows to the frames this layout was
        // saved with (no-op for the built-in presets, which predate frames).
        // This must happen BEFORE the windows are presented below, so panels
        // opening fresh come back on the right display at the right spot.
        FloatingWindowFrameStore.shared.restore(
            preset.windowFrames,
            applyingToOpenPanels: layout.allOpenPanels)
        activePresetID = id
        // Present every panel the recalled layout now has open (and let the
        // ones it dropped close themselves).
        NotificationCenter.default.post(name: .workspaceLayoutRecalled, object: nil)
    }

    /// Frames of the panels currently open — the position half of a preset.
    private func currentWindowFrames() -> [String: StoredFrame] {
        FloatingWindowFrameStore.shared.snapshot(kinds: layout.allOpenPanels)
    }

    // MARK: - Rename / Delete

    func rename(_ id: UUID, to newName: String) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[idx].name = newName
        presets[idx].updatedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        guard let idx = presets.firstIndex(where: { $0.id == id }) else { return }
        // Prevent deleting built-in presets.
        guard !presets[idx].isBuiltIn else { return }
        presets.remove(at: idx)
        if activePresetID == id { activePresetID = nil }
        save()
    }

    // MARK: - Built-in Presets

    enum BuiltInPreset: String, CaseIterable {
        case `default` = "Default"
        case focus = "Focus"
        case dashboard = "Dashboard"

        var displayName: String { rawValue }

        /// The numbered slot this built-in occupies (1–3).
        var slot: Int {
            switch self {
            case .default: return 1
            case .focus: return 2
            case .dashboard: return 3
            }
        }

        /// The panels that make up this built-in preset. The canvas/tiling
        /// system is gone, so everything opens as a floating window; the old
        /// grid geometry is no longer meaningful.
        func panels(agentID: UUID) -> [WorkspacePanelKind] {
            switch self {
            case .default:
                return [.agents, .appLauncher, .agentChat(agentID)]
            case .focus:
                return [.agentChat(agentID)]
            case .dashboard:
                return [.agents, .appLauncher, .agentChat(agentID), .kanban, .notesMD]
            }
        }
    }

    private func ensureBuiltInPresets() {
        let navigatorID = WorkspaceStore().navigator.id
        for builtIn in BuiltInPreset.allCases {
            let panels = builtIn.panels(agentID: navigatorID)
            if let idx = presets.firstIndex(where: { $0.name == builtIn.displayName }) {
                // Refresh built-in presets so their navigator chat panel
                // always points to the current navigator agent. Stale IDs
                // cause "Agent Not Found" when the preset is recalled.
                var refreshed = WorkspaceLayoutPreset(
                    id: presets[idx].id,
                    name: builtIn.displayName,
                    slot: builtIn.slot,
                    canvasTiles: [],
                    floatingPanels: panels,
                    isLocked: false
                )
                refreshed.isBuiltIn = true
                presets[idx] = refreshed
            } else {
                var preset = WorkspaceLayoutPreset(
                    name: builtIn.displayName,
                    slot: builtIn.slot,
                    canvasTiles: [],
                    floatingPanels: panels,
                    isLocked: false
                )
                preset.isBuiltIn = true
                presets.append(preset)
            }
        }
        save()
    }

    // MARK: - Persistence

    private func save() {
        let data = try? JSONEncoder().encode(presets)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        if let decoded = try? JSONDecoder().decode([WorkspaceLayoutPreset].self, from: data) {
            presets = decoded
            migrateGridResolutionIfNeeded()
        } else {
            // Don't silently wipe the user's saved layouts if the schema drifted.
            // Preserve the raw blob for diagnostics and fall back to built-ins.
            UserDefaults.standard.set(data, forKey: defaultsKey + ".corrupt")
            print("WorkspaceLayoutPresetStore: failed to decode saved presets. Corrupt data preserved at \(defaultsKey).corrupt")
        }
    }

    /// One-time migration: scale presets saved on the old 12×8 grid up to the
    /// current 24×16 grid. Doubles every tile's col/row/colSpan/rowSpan.
    private func migrateGridResolutionIfNeeded() {
        let savedVersion = UserDefaults.standard.integer(forKey: gridVersionKey)
        guard savedVersion < currentGridVersion else { return }
        for presetIdx in presets.indices {
            for tileIdx in presets[presetIdx].canvasTiles.indices {
                presets[presetIdx].canvasTiles[tileIdx].col *= 2
                presets[presetIdx].canvasTiles[tileIdx].row *= 2
                presets[presetIdx].canvasTiles[tileIdx].colSpan *= 2
                presets[presetIdx].canvasTiles[tileIdx].rowSpan *= 2
            }
        }
        UserDefaults.standard.set(currentGridVersion, forKey: gridVersionKey)
        save()
    }
}
