import SwiftUI

// MARK: - Workspace Panel Kind
//
// Identifies a *top-level* panel the user can have open in the main workspace
// — an agent's chat, or one of the app-level screens (Notes.md, Apple Notes,
// Calendar, Reminders, Contacts, Canvas, Kanban). Distinct from `PanelType`,
// which stays scoped to the Plans/Tasks/Terminal sub-panels docked alongside
// a single agent's chat inside `ChatView` — that subsystem is unchanged.

enum WorkspacePanelKind: Hashable, Codable, Sendable {
    case agentChat(UUID)
    case notesMD
    case appleNotes
    case calendar
    case reminders
    case contacts
    case canvas
    case kanban
    case numbers
    case whatsapp
    /// A WKWebView UI plugin, identified by its manifest id (see
    /// `PluginManifest`/`PluginService`). Unlike the other cases, this one is
    /// data-driven — there's no fixed enum case per plugin. `icon` returns a
    /// generic fallback and `staticDisplayName` returns nil (same pattern as
    /// `.agentChat`) since resolving the real name/icon needs `PluginService`,
    /// which this enum has no access to; callers that have it (ContentView's
    /// `title(for:)`, `WorkspacePanelWindowView`'s `title`) special-case this
    /// exactly like they already special-case `.agentChat`.
    case plugin(String)
    /// Shell command execution log. Used to live inside a single agent's chat
    /// as a `PanelType` sub-panel; moved here so it's a normal top-level
    /// "Swift Apps" item instead — one Terminal, independent of any agent.
    case terminal

    var icon: String {
        switch self {
        case .agentChat: return "bubble.left.and.bubble.right"
        case .notesMD: return "doc.text"
        case .appleNotes: return "note.text"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.2"
        case .canvas: return "rectangle.3.group"
        case .kanban: return "rectangle.split.3x1"
        case .numbers: return "tablecells"
        case .whatsapp: return "message"
        case .plugin: return "puzzlepiece.extension"
        case .terminal: return "terminal"
        }
    }

    /// Stable identifier for per-panel-kind persisted state (e.g. a custom
    /// color in `ThemeStore`) that isn't tied to any one instance. All panels
    /// of the same kind share one key — individual agent chats and plugin
    /// instances are NOT distinguished here (that granularity isn't needed
    /// for panel theming and would blow up the color-picker list).
    var themeStorageKey: String {
        switch self {
        case .agentChat: return "agentChat"
        case .notesMD: return "notesMD"
        case .appleNotes: return "appleNotes"
        case .calendar: return "calendar"
        case .reminders: return "reminders"
        case .contacts: return "contacts"
        case .canvas: return "canvas"
        case .kanban: return "kanban"
        case .numbers: return "numbers"
        case .whatsapp: return "whatsapp"
        case .plugin: return "plugin"
        case .terminal: return "terminal"
        }
    }

    /// Static display name for non-agent panels. Agent chat panels resolve
    /// their name from `WorkspaceStore` at the view layer instead, since the
    /// name can change (rename) independently of this identity.
    var staticDisplayName: String? {
        switch self {
        case .agentChat: return nil
        case .notesMD: return "Notes.md"
        case .appleNotes: return "Apple Notes"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .canvas: return "Canvas"
        case .kanban: return "Kanban"
        case .numbers: return "Numbers"
        case .whatsapp: return "WhatsApp"
        case .plugin: return nil
        case .terminal: return "Terminal"
        }
    }

    /// Minimum comfortable column width. Agent chat panels host their own
    /// nested Plans/Tasks/Terminal sub-panels (see `ChatView`'s own
    /// `ResizablePanelHost`), so squeezing one down to a generic panel's
    /// minimum would squish that inner layout unreadable — the exact bug this
    /// value exists to prevent. Simpler single-content panels can go narrower.
    var minColumnWidth: CGFloat {
        switch self {
        case .agentChat: return 560
        default: return 320
        }
    }

    /// Stable string key for width/height persistence (Dictionary can't be
    /// keyed by an arbitrary Codable enum in a plain UserDefaults plist, so
    /// sizes are stored under this string instead).
    var storageKey: String {
        switch self {
        case .agentChat(let id): return "agentChat:\(id.uuidString)"
        case .notesMD: return "notesMD"
        case .appleNotes: return "appleNotes"
        case .calendar: return "calendar"
        case .reminders: return "reminders"
        case .contacts: return "contacts"
        case .canvas: return "canvas"
        case .kanban: return "kanban"
        case .numbers: return "numbers"
        case .whatsapp: return "whatsapp"
        case .plugin(let id): return "plugin:\(id)"
        case .terminal: return "terminal"
        }
    }
}

// MARK: - Workspace Row

/// One horizontal row of the workspace grid — a left-to-right sequence of
/// panels. Rows themselves stack top-to-bottom, so the overall workspace is a
/// 2-D grid of "quadrants" (any number of rows, any number of columns per
/// row) rather than a single endlessly-shrinking horizontal strip.
struct WorkspaceRow: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var panels: [WorkspacePanelKind] = []
}

// MARK: - Workspace Layout State

/// Tracks the workspace grid (rows of docked panels), which panels are
/// floating in their own windows instead, per-panel column widths, per-row
/// heights, and persists all of it across relaunch. The sidebar acts as a
/// *launcher*: selecting an item opens/focuses it here rather than replacing
/// whatever else is already open.
///
/// Placement: the very first panel ever opened docks immediately (so there's
/// a usable main window from launch); every panel after that opens as its
/// own floating window by default, matching the "professional AV app" style
/// of some inspiration apps — the user decides whether/where to dock it, not
/// the app. Docking (via a floating window's own "Dock" button, or dragging
/// it back) is Tetris-placed: it joins the current (last) row *if* that row
/// still has comfortable room for it at every panel's minimum column width;
/// otherwise it starts a brand new row below, rather than squeezing everything
/// already in that row past readability. The user can always override this
/// manually via each docked panel's "Move to New Row" / "Move Up" / "Move
/// Down" actions.
@Observable
@MainActor
final class WorkspaceLayoutState {

    static let shared = WorkspaceLayoutState()

    private(set) var rows: [WorkspaceRow] = []

    /// Panels currently open in their own floating window rather than docked
    /// into `rows`. New panels open floating by default (see `open(_:)`) —
    /// only the very first panel the user ever opens docks automatically, so
    /// there's always a usable main window on first launch.
    private(set) var floatingPanels: Set<WorkspacePanelKind> = []

    /// Docked width per panel (by storage key), within whatever row it's in.
    /// The trailing panel in each row is always flexible and ignores this.
    private var columnWidths: [String: CGFloat] = [:]
    /// Docked height per row (by row id), for every row except the last,
    /// which is always flexible.
    private var rowHeights: [UUID: CGFloat] = [:]

    /// The most recently measured width of the workspace content area,
    /// updated reactively from `ContentView` via a geometry read. Used only
    /// to decide whether a newly opened panel fits in the current row.
    var availableWidth: CGFloat = 1_000

    private let defaultsKey = "SwiftMaestro.WorkspaceLayout"
    private static let dividerAllowance: CGFloat = 10

    init() {
        load()
    }

    // MARK: - Queries

    func isOpen(_ kind: WorkspacePanelKind) -> Bool {
        floatingPanels.contains(kind) || rows.contains { $0.panels.contains(kind) }
    }

    func isFloating(_ kind: WorkspacePanelKind) -> Bool {
        floatingPanels.contains(kind)
    }

    /// All docked open panels in row-major (top-to-bottom, left-to-right)
    /// order. Does not include floating panels.
    var allOpenPanels: [WorkspacePanelKind] {
        rows.flatMap(\.panels)
    }

    private func rowIndex(of kind: WorkspacePanelKind) -> Int? {
        rows.firstIndex { $0.panels.contains(kind) }
    }

    // MARK: - Open / close

    enum OpenResult {
        case alreadyOpen
        /// This was the very first panel ever opened — docked immediately so
        /// there's a usable main window.
        case dockedDirectly
        /// Opened as a new floating window — the caller is responsible for
        /// actually presenting it via `openWindow(id:value:)`.
        case floated
    }

    /// Open a panel. The very first panel opened (nothing docked or floating
    /// yet) docks immediately; every panel after that opens as a floating
    /// window by default — the user decides whether/where to dock it. No-op
    /// if already open either way.
    @discardableResult
    func open(_ kind: WorkspacePanelKind) -> OpenResult {
        guard !isOpen(kind) else { return .alreadyOpen }

        if rows.isEmpty && floatingPanels.isEmpty {
            rows.append(WorkspaceRow(panels: [kind]))
            save()
            return .dockedDirectly
        }

        floatingPanels.insert(kind)
        save()
        return .floated
    }

    /// Dock a currently-floating panel into the workspace grid — Tetris-
    /// placed into the current row if it fits, else a new row below. No-op if
    /// `kind` isn't currently floating. Does not close the panel's floating
    /// window; the caller (the window's own "Dock" button) is responsible for
    /// dismissing it.
    func dock(_ kind: WorkspacePanelKind) {
        guard floatingPanels.remove(kind) != nil else { return }
        if let lastIndex = rows.indices.last, fitsInRow(rows[lastIndex], adding: kind) {
            rows[lastIndex].panels.append(kind)
        } else {
            rows.append(WorkspaceRow(panels: [kind]))
        }
        save()
    }

    /// Pop a currently-docked panel back out into its own floating window.
    /// The caller is responsible for actually presenting the window via
    /// `openWindow(id:value:)`.
    func float(_ kind: WorkspacePanelKind) {
        guard let rowIdx = rowIndex(of: kind) else { return }
        rows[rowIdx].panels.removeAll { $0 == kind }
        columnWidths[kind.storageKey] = nil
        if rows[rowIdx].panels.isEmpty {
            let removedID = rows[rowIdx].id
            rows.remove(at: rowIdx)
            rowHeights[removedID] = nil
        }
        floatingPanels.insert(kind)
        save()
    }

    /// Whether `kind` can join `row` without squeezing any panel (existing or
    /// new) below its comfortable minimum column width, given the last
    /// measured workspace width.
    private func fitsInRow(_ row: WorkspaceRow, adding kind: WorkspacePanelKind) -> Bool {
        guard !row.panels.isEmpty else { return true }
        let widths = row.panels.map(\.minColumnWidth) + [kind.minColumnWidth]
        let dividers = CGFloat(widths.count - 1) * Self.dividerAllowance
        let required = widths.reduce(0, +) + dividers
        return required <= availableWidth
    }

    /// Close a panel entirely, whether docked or floating. Does not dismiss
    /// the panel's floating window if it has one — callers closing a floating
    /// window should dismiss the window itself, which the user does directly
    /// via its own close button.
    func close(_ kind: WorkspacePanelKind) {
        if floatingPanels.remove(kind) != nil {
            save()
            return
        }
        guard let idx = rowIndex(of: kind) else { return }
        rows[idx].panels.removeAll { $0 == kind }
        columnWidths[kind.storageKey] = nil
        if rows[idx].panels.isEmpty {
            let removedID = rows[idx].id
            rows.remove(at: idx)
            rowHeights[removedID] = nil
        }
        save()
    }

    // MARK: - Reordering — within a row

    func moveWithinRow(_ kind: WorkspacePanelKind, to newIndex: Int) {
        guard let rowIdx = rowIndex(of: kind),
              let oldIndex = rows[rowIdx].panels.firstIndex(of: kind) else { return }
        var panels = rows[rowIdx].panels
        panels.remove(at: oldIndex)
        let adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex
        panels.insert(kind, at: min(max(adjusted, 0), panels.count))
        rows[rowIdx].panels = panels
        save()
    }

    /// Column index of `kind` within its own row, and that row's panel count
    /// — used by the panel header to decide whether Move Left/Right apply.
    func columnPosition(of kind: WorkspacePanelKind) -> (index: Int, count: Int)? {
        guard let rowIdx = rowIndex(of: kind),
              let colIdx = rows[rowIdx].panels.firstIndex(of: kind) else { return nil }
        return (colIdx, rows[rowIdx].panels.count)
    }

    /// Row index of `kind`, and the total row count — used by the panel
    /// header to decide whether Move Up/Down apply.
    func rowPosition(of kind: WorkspacePanelKind) -> (index: Int, count: Int)? {
        guard let rowIdx = rowIndex(of: kind) else { return nil }
        return (rowIdx, rows.count)
    }

    // MARK: - Reordering — across rows (manual quadrant control)

    /// Pull `kind` out of its current row and give it a brand new row
    /// immediately below that row — the manual escape hatch for turning a
    /// crowded row into a proper quadrant layout.
    func sendToNewRow(_ kind: WorkspacePanelKind) {
        guard let rowIdx = rowIndex(of: kind) else { return }
        rows[rowIdx].panels.removeAll { $0 == kind }
        let insertAt = rowIdx + 1
        if rows[rowIdx].panels.isEmpty {
            rows[rowIdx] = WorkspaceRow(panels: [kind])
        } else {
            rows.insert(WorkspaceRow(panels: [kind]), at: min(insertAt, rows.count))
        }
        save()
    }

    /// Merge `kind` into the row above (or below) it, appending it as the
    /// last column of that row. If its own row becomes empty, the row is
    /// removed.
    func moveToAdjacentRow(_ kind: WorkspacePanelKind, direction: RowMoveDirection) {
        guard let rowIdx = rowIndex(of: kind) else { return }
        let targetIdx = direction == .up ? rowIdx - 1 : rowIdx + 1
        guard rows.indices.contains(targetIdx) else { return }

        rows[rowIdx].panels.removeAll { $0 == kind }
        let emptiedRowID = rows[rowIdx].panels.isEmpty ? rows[rowIdx].id : nil
        if rows[rowIdx].panels.isEmpty {
            rows.remove(at: rowIdx)
        }
        // Recompute the target index in case removing the source row shifted it.
        let adjustedTarget = (emptiedRowID != nil && targetIdx > rowIdx) ? targetIdx - 1 : targetIdx
        guard rows.indices.contains(adjustedTarget) else {
            // Target row vanished (shouldn't normally happen) — give it back
            // its own row rather than dropping the panel.
            rows.insert(WorkspaceRow(panels: [kind]), at: min(rowIdx, rows.count))
            save()
            return
        }
        rows[adjustedTarget].panels.append(kind)
        if let emptiedRowID { rowHeights[emptiedRowID] = nil }
        save()
    }

    enum RowMoveDirection { case up, down }

    // MARK: - Sizing

    /// A two-way binding to a panel's column width within its row, persisted
    /// on every change.
    func widthBinding(for kind: WorkspacePanelKind) -> Binding<CGFloat> {
        Binding(
            get: { self.columnWidths[kind.storageKey] ?? max(kind.minColumnWidth, 420) },
            set: { newValue in
                self.columnWidths[kind.storageKey] = newValue
                self.save()
            }
        )
    }

    /// A two-way binding to a row's height, persisted on every change.
    func heightBinding(for row: WorkspaceRow) -> Binding<CGFloat> {
        Binding(
            get: { self.rowHeights[row.id] ?? 420 },
            set: { newValue in
                self.rowHeights[row.id] = newValue
                self.save()
            }
        )
    }

    /// Called from `ContentView` whenever the workspace content area's
    /// measured width changes, so future `open(_:)` placement decisions use
    /// an up-to-date width.
    func updateAvailableWidth(_ width: CGFloat) {
        guard width > 0, abs(width - availableWidth) > 1 else { return }
        availableWidth = width
    }

    // MARK: - Persistence

    private func save() {
        let data = try? JSONEncoder().encode(rows)
        UserDefaults.standard.set(data, forKey: defaultsKey + ".rows")
        UserDefaults.standard.set(columnWidths.mapValues(Double.init), forKey: defaultsKey + ".columnWidths")
        let heightsByKey = Dictionary(uniqueKeysWithValues: rowHeights.map { ($0.key.uuidString, Double($0.value)) })
        UserDefaults.standard.set(heightsByKey, forKey: defaultsKey + ".rowHeights")
        let floatingData = try? JSONEncoder().encode(Array(floatingPanels))
        UserDefaults.standard.set(floatingData, forKey: defaultsKey + ".floatingPanels")
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey + ".rows"),
           let decoded = try? JSONDecoder().decode([WorkspaceRow].self, from: data) {
            rows = decoded
        }
        if let widths = UserDefaults.standard.dictionary(forKey: defaultsKey + ".columnWidths") as? [String: Double] {
            columnWidths = widths.mapValues { CGFloat($0) }
        }
        if let heights = UserDefaults.standard.dictionary(forKey: defaultsKey + ".rowHeights") as? [String: Double] {
            rowHeights = Dictionary(uniqueKeysWithValues: heights.compactMap { key, value in
                UUID(uuidString: key).map { ($0, CGFloat(value)) }
            })
        }
        if let floatingData = UserDefaults.standard.data(forKey: defaultsKey + ".floatingPanels"),
           let decoded = try? JSONDecoder().decode([WorkspacePanelKind].self, from: floatingData) {
            floatingPanels = Set(decoded)
        }
    }
}
