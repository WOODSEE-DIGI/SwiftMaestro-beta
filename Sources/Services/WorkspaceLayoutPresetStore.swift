import SwiftUI

// MARK: - Workspace Layout Preset

/// A named snapshot of the workspace canvas layout. Captures which panels are
/// open, where they sit on the grid, and which are floating — so the user can
/// save, recall, and share layout configurations.
struct WorkspaceLayoutPreset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// The numbered slot (1–10) this preset occupies in the workspace switcher.
    /// Nil if unassigned (legacy presets before slots were introduced).
    var slot: Int?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// The canvas tiles at save time (grid positions, sizes, z-order).
    var canvasTiles: [CanvasTile]
    /// Panels that were floating in their own windows.
    var floatingPanels: [WorkspacePanelKind]
    /// Whether the workspace was locked.
    var isLocked: Bool

    /// Built-in presets ship with the app and cannot be deleted.
    var isBuiltIn: Bool = false
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
        activePresetID = id
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

        func tiles(agentID: UUID) -> [CanvasTile] {
            switch self {
            case .default:
                // Agents (6 cols, 10 rows) + Apps (6 cols, 6 rows) left,
                // Navigator chat (18 cols, 16 rows) center.
                return [
                    CanvasTile(kinds: [.agents], col: 0, row: 0, colSpan: 6, rowSpan: 10, z: 1),
                    CanvasTile(kinds: [.appLauncher], col: 0, row: 10, colSpan: 6, rowSpan: 6, z: 2),
                    CanvasTile(kinds: [.agentChat(agentID)], col: 6, row: 0, colSpan: 18, rowSpan: 16, z: 3),
                ]
            case .focus:
                // Single full-screen chat, no chrome — maximum focus.
                return [
                    CanvasTile(kinds: [.agentChat(agentID)], col: 0, row: 0, colSpan: 24, rowSpan: 16, z: 1),
                ]
            case .dashboard:
                // Agents + Apps left column, chat center, tasks right.
                return [
                    CanvasTile(kinds: [.agents], col: 0, row: 0, colSpan: 4, rowSpan: 8, z: 1),
                    CanvasTile(kinds: [.appLauncher], col: 0, row: 8, colSpan: 4, rowSpan: 8, z: 2),
                    CanvasTile(kinds: [.agentChat(agentID)], col: 4, row: 0, colSpan: 14, rowSpan: 16, z: 3),
                    CanvasTile(kinds: [.kanban], col: 18, row: 0, colSpan: 6, rowSpan: 8, z: 4),
                    CanvasTile(kinds: [.notesMD], col: 18, row: 8, colSpan: 6, rowSpan: 8, z: 5),
                ]
            }
        }

        var floatingPanels: [WorkspacePanelKind] {
            switch self {
            case .default, .focus, .dashboard: return []
            }
        }
    }

    private func ensureBuiltInPresets() {
        let navigatorID = WorkspaceStore().navigator.id
        for builtIn in BuiltInPreset.allCases {
            if let idx = presets.firstIndex(where: { $0.name == builtIn.displayName }) {
                // Refresh built-in presets so their navigator chat tile always
                // points to the current navigator agent. Stale IDs cause
                // "Agent Not Found" when the preset is recalled.
                var refreshed = WorkspaceLayoutPreset(
                    id: presets[idx].id,
                    name: builtIn.displayName,
                    slot: builtIn.slot,
                    canvasTiles: builtIn.tiles(agentID: navigatorID),
                    floatingPanels: builtIn.floatingPanels,
                    isLocked: false
                )
                refreshed.isBuiltIn = true
                presets[idx] = refreshed
            } else {
                var preset = WorkspaceLayoutPreset(
                    name: builtIn.displayName,
                    slot: builtIn.slot,
                    canvasTiles: builtIn.tiles(agentID: navigatorID),
                    floatingPanels: builtIn.floatingPanels,
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
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([WorkspaceLayoutPreset].self, from: data) else { return }
        presets = decoded
        migrateGridResolutionIfNeeded()
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
