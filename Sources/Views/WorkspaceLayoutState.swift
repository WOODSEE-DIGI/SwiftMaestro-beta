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
    case maps
    case photos
    /// Apple Mail bridge: launch Mail, compose drafts, and read messages.
    case mail
    case whatsapp
    case discord
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
    /// Live view of the internal agent bus: topics, messages, and subscribers.
    case busMonitor
    /// Audio input/output control panel: device selection, mute, and level meter.
    case audioControl
    /// Tethered / live multi-source camera capture (USB PTP, HDMI, webcam, NDI).
    case tethering
    /// Local RTMP/SRT/WebRTC ingest server.
    case streamIngest
    /// RTMP/SRT broadcast publisher to platforms or custom endpoints.
    case broadcast
    /// Route and switch between sources; send to publisher or recorder.
    case streamMixer
    /// Discover and preview NDI sources on the network.
    case ndiBrowser
    /// Color adjustments / LUT / filter panel for live video sources.
    case colorAdjustments
    /// Multi-layer scene composer with sources and overlays.
    case scenes
    /// The agent navigator list (Maestro + project agents). A normal tiling
    /// panel so it can dock/float/move like every other panel instead of living
    /// in a fixed left sidebar.
    case agents
    /// A movable launcher containing the Apple Apps, Swift Apps, and Plugins
    /// sections from the sidebar. Users can dock it anywhere in the workspace
    /// grid (e.g. under Plans) when the sidebar is overcrowded.
    case appLauncher
    /// Internal web browser with WebKit rendering and Chromium CDP automation.
    case webBrowser
    /// MaestroDAM — digital asset management browser (catalog grid, ratings,
    /// search). Competes with Adobe Bridge / NeoFinder; see
    /// `docs/26.07.30-MaestroDAM-Architecture.md`.
    case damBrowser
    /// MaestroDocs — native document viewer/editor (PDF, Word, RTF, ODT,
    /// XLSX, PPTX, EPUB, iWork, text) on the MaestroDocs engine.
    case maestroDocs
    /// MaestroBooks — Xero-compatible invoicing (A4 tax invoice PDFs filed
    /// in MaestroDAM, Xero CSV export, agent-driven).
    case maestroBooks
    /// MaestroDB — dynamic-schema database (Airtable/Notion alternative) with
    /// grid + shared-kanban board views on GRDB.
    case maestroDB

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
        case .maps: return "map"
        case .photos: return "photo.stack"
        case .mail: return "envelope"
        case .whatsapp: return "message"
        case .discord: return "bubble.left.and.text.bubble.right.fill"
        case .plugin: return "puzzlepiece.extension"
        case .terminal: return "terminal"
        case .busMonitor: return "network"
        case .audioControl: return "mic"
        case .tethering: return "camera.viewfinder"
        case .streamIngest: return "arrow.down.circle"
        case .broadcast: return "arrow.up.circle"
        case .streamMixer: return "arrow.triangle.merge"
        case .ndiBrowser: return "network.badge.shield.half.filled"
        case .colorAdjustments: return "slider.horizontal.3"
        case .scenes: return "rectangle.stack"
        case .agents: return "person.3"
        case .appLauncher: return "square.grid.2x2"
        case .webBrowser: return "globe"
        case .damBrowser: return "photo.on.rectangle.angled"
        case .maestroDocs: return "doc.richtext"
        case .maestroBooks: return "dollarsign.circle"
        case .maestroDB: return "tablecells"
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
        case .maps: return "maps"
        case .photos: return "photos"
        case .mail: return "mail"
        case .whatsapp: return "whatsapp"
        case .discord: return "discord"
        case .plugin: return "plugin"
        case .terminal: return "terminal"
        case .busMonitor: return "busMonitor"
        case .audioControl: return "audioControl"
        case .tethering: return "tethering"
        case .streamIngest: return "streamIngest"
        case .broadcast: return "broadcast"
        case .streamMixer: return "streamMixer"
        case .ndiBrowser: return "ndiBrowser"
        case .colorAdjustments: return "colorAdjustments"
        case .scenes: return "scenes"
        case .agents: return "agents"
        case .appLauncher: return "appLauncher"
        case .webBrowser: return "webBrowser"
        case .damBrowser: return "damBrowser"
        case .maestroDocs: return "maestroDocs"
        case .maestroBooks: return "maestroBooks"
        case .maestroDB: return "maestroDB"
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
        case .maps: return "Maps"
        case .photos: return "Photos"
        case .mail: return "Mail"
        case .whatsapp: return "WhatsApp"
        case .discord: return "Discord"
        case .plugin: return nil
        case .terminal: return "Terminal"
        case .busMonitor: return "Bus Monitor"
        case .audioControl: return "Audio Control"
        case .tethering: return "Cameras"
        case .streamIngest: return "Stream Ingest"
        case .broadcast: return "Broadcast"
        case .streamMixer: return "Stream Mixer"
        case .ndiBrowser: return "NDI Browser"
        case .colorAdjustments: return "Color Adjustments"
        case .scenes: return "Scenes"
        case .agents: return "Agents"
        case .appLauncher: return "Apps"
        case .webBrowser: return "SwiftBrowser"
        case .damBrowser: return "MaestroDAM"
        case .maestroDocs: return "MaestroDocs"
        case .maestroBooks: return "MaestroBooks"
        case .maestroDB: return "MaestroDB"
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
        case .maps: return "maps"
        case .photos: return "photos"
        case .mail: return "mail"
        case .whatsapp: return "whatsapp"
        case .discord: return "discord"
        case .plugin(let id): return "plugin:\(id)"
        case .terminal: return "terminal"
        case .busMonitor: return "busMonitor"
        case .audioControl: return "audioControl"
        case .tethering: return "tethering"
        case .streamIngest: return "streamIngest"
        case .broadcast: return "broadcast"
        case .streamMixer: return "streamMixer"
        case .ndiBrowser: return "ndiBrowser"
        case .colorAdjustments: return "colorAdjustments"
        case .scenes: return "scenes"
        case .agents: return "agents"
        case .appLauncher: return "appLauncher"
        case .webBrowser: return "webBrowser"
        case .damBrowser: return "damBrowser"
        case .maestroDocs: return "maestroDocs"
        case .maestroBooks: return "maestroBooks"
        case .maestroDB: return "maestroDB"
        }
    }
}

// MARK: - Tiling Drop Zone

/// Where a dragged panel should land relative to the tile it is dropped on.
/// `center` stacks it with the target; the four cardinal directions split
/// the target tile in half and place the dragged panel on that side.
enum TilingDropZone: String, Codable, Hashable, Sendable, CaseIterable {
    case left, right, top, bottom, center

    /// The split axis implied by this zone, if any.
    var splitAxis: LayoutAxis? {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        case .center: return nil
        }
    }

    /// When creating a new split, `true` means the dragged panel becomes the
    /// `first` child (left/top); `false` means the `second` child (right/bottom).
    var draggedPanelIsFirst: Bool? {
        switch self {
        case .left, .top: return true
        case .right, .bottom: return false
        case .center: return nil
        }
    }
}

// MARK: - Layout Axis

/// The split direction of a binary-tree layout node. Kept as a custom type
/// (rather than SwiftUI `Axis`) because it must be `Codable`/`Sendable`.
enum LayoutAxis: String, Codable, Hashable, Sendable {
    case horizontal, vertical
}

// MARK: - Layout Node

/// Recursive binary tree representing the tiled workspace. A node is either a
/// single panel leaf, a stack of panels sharing one tile (center drop), or a
/// split that divides space between two children. This model can represent
/// any quadrant/location the user drags a panel into, without locking the UI
/// into a fixed number of rows or columns.
indirect enum LayoutNode: Codable, Hashable, Sendable {
    case leaf(WorkspacePanelKind)
    case stack([WorkspacePanelKind])
    case split(axis: LayoutAxis, ratio: Double, first: LayoutNode, second: LayoutNode)

    /// All individual panel kinds contained in this subtree.
    func allPanels() -> [WorkspacePanelKind] {
        switch self {
        case .leaf(let kind): return [kind]
        case .stack(let kinds): return kinds
        case .split(_, _, let first, let second): return first.allPanels() + second.allPanels()
        }
    }

    /// Whether the subtree contains the panel.
    func contains(_ kind: WorkspacePanelKind) -> Bool {
        switch self {
        case .leaf(let k): return k == kind
        case .stack(let kinds): return kinds.contains(kind)
        case .split(_, _, let first, let second): return first.contains(kind) || second.contains(kind)
        }
    }

    /// Walk the tree to find the rightmost/bottommost leaf panel. Prefers the
    /// `second` child at each split (right for horizontal, bottom for vertical).
    func rightmostLeaf() -> WorkspacePanelKind? {
        switch self {
        case .leaf(let k): return k
        case .stack(let kinds): return kinds.last
        case .split(_, _, _, let second):
            return second.rightmostLeaf() ?? self.leftmostLeaf()
        }
    }

    /// Walk the tree to find the rightmost leaf of the TOP row. Like
    /// `rightmostLeaf()` but at VERTICAL splits it descends into the TOP
    /// (`first`) child — the main content row — instead of the bottom row.
    /// Used when docking a new panel to the right so it lands beside the
    /// chat/browser row rather than next to a bottom-docked panel (e.g.
    /// MaestroDB), which is where plain `rightmostLeaf()` would put it once
    /// a bottom row exists.
    func rightmostTopLeaf() -> WorkspacePanelKind? {
        switch self {
        case .leaf(let k): return k
        case .stack(let kinds): return kinds.last
        case .split(let axis, _, let first, let second):
            switch axis {
            case .horizontal:
                return second.rightmostTopLeaf() ?? first.rightmostTopLeaf()
            case .vertical:
                return first.rightmostTopLeaf() ?? second.rightmostTopLeaf()
            }
        }
    }

    private func leftmostLeaf() -> WorkspacePanelKind? {
        switch self {
        case .leaf(let k): return k
        case .stack(let kinds): return kinds.first
        case .split(_, _, let first, _):
            return first.leftmostLeaf()
        }
    }

    /// A path of first/second decisions from the root to the target panel.
    func path(to kind: WorkspacePanelKind) -> LayoutPath? {
        switch self {
        case .leaf(let k):
            return k == kind ? LayoutPath() : nil
        case .stack(let kinds):
            return kinds.contains(kind) ? LayoutPath() : nil
        case .split(_, _, let first, let second):
            if let firstPath = first.path(to: kind) {
                return LayoutPath(steps: [.first] + firstPath.steps)
            }
            if let secondPath = second.path(to: kind) {
                return LayoutPath(steps: [.second] + secondPath.steps)
            }
            return nil
        }
    }

    /// Remove the first occurrence of `kind` from this subtree and simplify
    /// the resulting tree (collapse single-child splits, empty stacks, etc.).
    /// Returns the new node, or `nil` if the subtree becomes empty.
    func removing(_ kind: WorkspacePanelKind) -> LayoutNode? {
        switch self {
        case .leaf(let k):
            return k == kind ? nil : self
        case .stack(let kinds):
            let filtered = kinds.filter { $0 != kind }
            if filtered.isEmpty { return nil }
            if filtered.count == 1 { return .leaf(filtered[0]) }
            return .stack(filtered)
        case .split(let axis, let ratio, let first, let second):
            if first.contains(kind) {
                guard let newFirst = first.removing(kind) else {
                    return second.simplified()
                }
                return .split(axis: axis, ratio: ratio, first: newFirst, second: second).simplified()
            } else if second.contains(kind) {
                guard let newSecond = second.removing(kind) else {
                    return first.simplified()
                }
                return .split(axis: axis, ratio: ratio, first: first, second: newSecond).simplified()
            }
            return self
        }
    }

    /// Insert `kind` relative to the node at `path`, in the requested `zone`.
    /// Returns a new node; if the path no longer exists, returns `self`.
    func inserting(_ kind: WorkspacePanelKind, at path: LayoutPath, zone: TilingDropZone) -> LayoutNode {
        if path.isEmpty {
            return insertAtSelf(kind, zone: zone)
        }
        switch self {
        case .leaf, .stack:
            // Path is invalid for a leaf; treat as a self-insert on the root.
            return insertAtSelf(kind, zone: zone)
        case .split(let axis, let ratio, let first, let second):
            guard let step = path.first else { return insertAtSelf(kind, zone: zone) }
            switch step {
            case .first:
                let rest = path.droppingFirst()
                let newFirst = first.inserting(kind, at: rest, zone: zone)
                return .split(axis: axis, ratio: ratio, first: newFirst, second: second)
            case .second:
                let rest = path.droppingFirst()
                let newSecond = second.inserting(kind, at: rest, zone: zone)
                return .split(axis: axis, ratio: ratio, first: first, second: newSecond)
            }
        }
    }

    private func insertAtSelf(_ kind: WorkspacePanelKind, zone: TilingDropZone) -> LayoutNode {
        switch zone {
        case .center:
            switch self {
            case .leaf(let existing):
                return .stack([existing, kind])
            case .stack(var kinds):
                if !kinds.contains(kind) { kinds.append(kind) }
                return .stack(kinds)
            case .split:
                // Cannot stack on a split; default to a right-side split.
                return .split(axis: .horizontal, ratio: 0.5, first: self, second: .leaf(kind))
            }
        default:
            guard let axis = zone.splitAxis, let firstSlot = zone.draggedPanelIsFirst else { return self }
            let split = LayoutNode.split(axis: axis, ratio: 0.5, first: self, second: .leaf(kind))
            if firstSlot {
                // dragged panel should be first: swap the self/leaf order but
                // keep ratio meaning "first child's fraction".
                return .split(axis: axis, ratio: 0.5, first: .leaf(kind), second: self)
            }
            return split
        }
    }

    /// Simplify single-child splits and empty stacks after a removal.
    private func simplified() -> LayoutNode? {
        switch self {
        case .leaf: return self
        case .stack(let kinds):
            if kinds.isEmpty { return nil }
            if kinds.count == 1 { return .leaf(kinds[0]) }
            return self
        case .split(_, _, let first, let second):
            let simpleFirst = first.simplified()
            let simpleSecond = second.simplified()
            if simpleFirst == nil { return simpleSecond }
            if simpleSecond == nil { return simpleFirst }
            return self
        }
    }
}

// MARK: - Layout Path

/// A path from the root of the layout tree to a specific node. Each step
/// chooses the first or second child of a split.
struct LayoutPath: Hashable, Sendable {
    enum Step: String, Codable, Hashable, Sendable {
        case first, second
    }
    var steps: [Step] = []

    var isEmpty: Bool { steps.isEmpty }
    var first: Step? { steps.first }

    func droppingFirst() -> LayoutPath {
        LayoutPath(steps: Array(steps.dropFirst()))
    }
}

// MARK: - Legacy Workspace Row / Column

// These types are kept solely for decoding the previous grid persistence
// format and migrating it into the binary tree model.

private struct LegacyColumn: Identifiable, Decodable, Equatable, Sendable {
    var id: UUID = UUID()
    var panels: [WorkspacePanelKind] = []
}

private struct LegacyRow: Identifiable, Decodable, Equatable, Sendable {
    var id: UUID = UUID()
    var columns: [LegacyColumn] = []

    enum CodingKeys: String, CodingKey {
        case id, columns, panels
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let columns = try? container.decode([LegacyColumn].self, forKey: .columns) {
            self.columns = columns
        } else if let panels = try? container.decode([WorkspacePanelKind].self, forKey: .panels) {
            self.columns = panels.map { LegacyColumn(panels: [$0]) }
        }
    }
}

// MARK: - Workspace Layout State

/// Tracks the tiled workspace (a recursive binary tree of panels), which
/// panels are floating in their own windows, per-split ratios, and the
/// workspace lock state. Selecting an item in the sidebar opens or focuses it;
/// dragging a panel by its grip rearranges the tree.
@Observable
@MainActor
final class WorkspaceLayoutState {

    static let shared = WorkspaceLayoutState()

    /// The root of the binary tiling tree. `nil` means an empty workspace.
    private(set) var root: LayoutNode?

    /// Panels currently open in their own floating window rather than docked
    /// into the tree. New panels open floating by default (see `open(_:)`)
    /// after the very first one, which docks immediately so the main window
    /// is never empty on first launch.
    private(set) var floatingPanels: Set<WorkspacePanelKind> = []

    /// When `true`, the workspace layout is locked and panels cannot be dragged
    /// or dropped. The lock toggle lives in the main toolbar.
    var isLocked = false

    /// Persisted split ratio per split node. Keyed by a deterministic hash of
    /// the split's path and the panels it contains, so the ratio survives a
    /// rebuild of the tree. Values are between 0.1 and 0.9.
    private var splitRatios: [String: Double] = [:]

    /// The most recently measured width of the workspace content area.
    /// Used to decide whether a newly opened panel fits comfortably.
    var availableWidth: CGFloat = 1_000

    private let defaultsKey = "SwiftMaestro.WorkspaceLayout"
    private static let minRatio: Double = 0.1
    private static let maxRatio: Double = 0.9

    init() {
        load()
    }

    // MARK: - Queries

    func isOpen(_ kind: WorkspacePanelKind) -> Bool {
        floatingPanels.contains(kind) || root?.contains(kind) == true
    }

    func isFloating(_ kind: WorkspacePanelKind) -> Bool {
        floatingPanels.contains(kind)
    }

    /// All panels currently docked in the tree, in a stable traversal order.
    var allOpenPanels: [WorkspacePanelKind] {
        root?.allPanels() ?? []
    }

    /// Path of the given panel in the tree, or `nil` if floating or closed.
    func path(of kind: WorkspacePanelKind) -> LayoutPath? {
        root?.path(to: kind)
    }

    /// Whether the tree contains at least one split node.
    var hasMultipleTiles: Bool {
        guard let root else { return false }
        switch root {
        case .leaf, .stack: return false
        case .split: return true
        }
    }

    // MARK: - Open / close / float

    enum OpenResult {
        case alreadyOpen
        /// The very first panel opened into an empty workspace.
        case dockedDirectly
        /// Opened as a new floating window.
        case floated
    }

    /// Open a panel. By default it docks to the right of the existing layout.
    /// Pass `.bottom` (Shift) for a new row, or `nil` zone to float (Option).
    @discardableResult
    func open(_ kind: WorkspacePanelKind, zone: TilingDropZone? = .right) -> OpenResult {
        guard !isOpen(kind) else { return .alreadyOpen }

        if root == nil && floatingPanels.isEmpty {
            root = .leaf(kind)
            save()
            return .dockedDirectly
        }

        guard let zone else {
            // nil zone → float
            floatingPanels.insert(kind)
            save()
            return .floated
        }

        // Dock a brand-new panel into the tree. Instead of splitting the
        // entire root (which would squish everything to 50%), find the
        // rightmost content leaf and insert relative to it.
        guard let current = self.root else {
            self.root = .leaf(kind)
            save()
            return .dockedDirectly
        }

        if zone == .bottom {
            // Bottom-docking must create a true second ROW spanning the full
            // main content width — not a vertical split nested inside the
            // rightmost column (which renders as just another right panel).
            // The workspace root is normally `.split(.horizontal, chrome, main)`;
            // split `main` vertically so the new panel sits below everything.
            if case .split(axis: .horizontal, let ratio, let first, let second) = current,
               first.contains(.agents) {
                self.root = .split(axis: .horizontal, ratio: ratio, first: first,
                                   second: .split(axis: .vertical, ratio: 0.65,
                                                  first: second, second: .leaf(kind)))
            } else {
                // No chrome column — split the whole root vertically.
                self.root = .split(axis: .vertical, ratio: 0.65,
                                   first: current, second: .leaf(kind))
            }
            save()
            return .dockedDirectly
        }

        // For .right, target the rightmost leaf of the TOP row so a bottom
        // row (MaestroDB etc.) doesn't capture the new panel next to itself.
        let targetLeaf = (zone == .right) ? current.rightmostTopLeaf() : current.rightmostLeaf()
        if let targetKind = targetLeaf,
           let targetPath = current.path(to: targetKind) {
            self.root = current.inserting(kind, at: targetPath, zone: zone)
        } else {
            // Fallback: split the root directly.
            switch zone {
            case .right:
                self.root = .split(axis: .horizontal, ratio: 0.5, first: current, second: .leaf(kind))
            case .left:
                self.root = .split(axis: .horizontal, ratio: 0.5, first: .leaf(kind), second: current)
            case .top:
                self.root = .split(axis: .vertical, ratio: 0.5, first: .leaf(kind), second: current)
            case .bottom, .center:
                self.root = .split(axis: .vertical, ratio: 0.5, first: current, second: .leaf(kind))
            }
        }
        save()
        return .dockedDirectly
    }

    /// Ensure the navigation "chrome" — the Agents navigator panel with the Apps
    /// launcher beneath it — is docked as a left-hand column of movable tiles,
    /// with the main workspace to its right. Called at launch. Only inserts the
    /// chrome when it's missing, so an existing saved layout keeps its
    /// right-hand panels untouched.
    func ensureChromeLayout(navigatorID: UUID) {
        let chrome = LayoutNode.split(
            axis: .vertical, ratio: 0.55,
            first: .leaf(.agents), second: .leaf(.appLauncher))

        guard let current = root else {
            root = .split(axis: .horizontal, ratio: 0.3,
                          first: chrome, second: .leaf(.agentChat(navigatorID)))
            save()
            return
        }
        guard !current.contains(.agents) else { return }
        root = .split(axis: .horizontal, ratio: 0.3, first: chrome, second: current)
        save()
    }

    /// Dock a floating panel into the tree in a given direction relative to the
    /// current root. `.left`/`.right` produce a horizontal (side-by-side column)
    /// split; `.top`/`.bottom` produce a vertical (stacked row) split. Defaults
    /// to `.bottom` to preserve the historical "new row underneath" behavior;
    /// callers that want a column pass an explicit direction (e.g. the floating
    /// window's "Dock to Right" action).
    func dock(_ kind: WorkspacePanelKind, zone: TilingDropZone = .bottom) {
        guard floatingPanels.remove(kind) != nil else { return }
        guard let root else {
            self.root = .leaf(kind)
            save()
            return
        }
        switch zone {
        case .right:
            self.root = .split(axis: .horizontal, ratio: 0.5, first: root, second: .leaf(kind))
        case .left:
            self.root = .split(axis: .horizontal, ratio: 0.5, first: .leaf(kind), second: root)
        case .top:
            self.root = .split(axis: .vertical, ratio: 0.5, first: .leaf(kind), second: root)
        case .bottom, .center:
            self.root = .split(axis: .vertical, ratio: 0.5, first: root, second: .leaf(kind))
        }
        save()
    }

    /// Dock a panel as the root of an otherwise empty workspace — used by the
    /// background drop target when every panel is floating. Handles both
    /// floating sources (the normal case) and defensive re-insertion.
    func dockAsRoot(_ kind: WorkspacePanelKind) {
        guard root == nil else { return }
        floatingPanels.remove(kind)
        root = .leaf(kind)
        save()
    }

    /// Pop a docked panel back out into its own floating window.
    func float(_ kind: WorkspacePanelKind) {
        guard root?.contains(kind) == true else { return }
        root = root?.removing(kind)
        floatingPanels.insert(kind)
        save()
    }

    /// Close a panel, whether docked or floating. Does not dismiss its window.
    func close(_ kind: WorkspacePanelKind) {
        if floatingPanels.remove(kind) != nil {
            save()
            return
        }
        root = root?.removing(kind)
        save()
    }

    /// Move a panel by dragging it from its current location onto the target
    /// panel `target` with the requested `zone`. If the source is floating, it
    /// is removed from the floating set and inserted into the tree. If `target`
    /// is no longer in the tree after the source is removed (e.g. source and
    /// target were the same), the source becomes the root leaf.
    func movePanel(_ kind: WorkspacePanelKind, to target: WorkspacePanelKind, zone: TilingDropZone) {
        guard !isLocked else { return }
        guard kind != target || floatingPanels.contains(kind) else { return }

        // Remove source from wherever it lives.
        let sourceWasFloating = floatingPanels.remove(kind) != nil
        if !sourceWasFloating {
            root = root?.removing(kind)
        }

        // Locate the target in the post-removal tree.
        guard root?.contains(target) == true else {
            if root == nil { root = .leaf(kind) }
            else { root = root?.inserting(kind, at: LayoutPath(), zone: .right) }
            save()
            return
        }

        guard let targetPath = root?.path(to: target) else {
            root = .leaf(kind)
            save()
            return
        }

        root = root?.inserting(kind, at: targetPath, zone: zone)
        save()
    }

    // MARK: - Split ratios

    /// Ratio for the split at the given path. Returns a clamped default if
    /// no persisted ratio exists.
    func ratio(for path: LayoutPath) -> Double {
        splitRatios[path.ratioKey] ?? 0.5
    }

    /// Update and persist the ratio for a split.
    func setRatio(_ ratio: Double, for path: LayoutPath) {
        splitRatios[path.ratioKey] = max(Self.minRatio, min(Self.maxRatio, ratio))
        save()
    }

    /// Binding to a split ratio so `TilingSplitView` can drive it directly.
    func ratioBinding(for path: LayoutPath) -> Binding<Double> {
        Binding(
            get: { self.ratio(for: path) },
            set: { newValue in
                self.setRatio(newValue, for: path)
            }
        )
    }

    // MARK: - Legacy reordering API compatibility

    // These methods are no-ops or simplified because the new tiling model is
    // manipulated by direct drag-and-drop. They are kept to avoid breaking
    // any remaining call sites that may invoke them.

    func moveWithinRow(_ kind: WorkspacePanelKind, to newColumnIndex: Int) { }
    func moveWithinColumn(_ kind: WorkspacePanelKind, direction: MoveDirection) { }
    func moveOutOfColumn(_ kind: WorkspacePanelKind) { }
    func moveIntoColumn(_ kind: WorkspacePanelKind, direction: MoveDirection) { }
    func sendToNewRow(_ kind: WorkspacePanelKind) { }
    func moveToAdjacentRow(_ kind: WorkspacePanelKind, direction: MoveDirection) { }

    enum MoveDirection { case up, down, left, right }

    // MARK: - Sizing

    func updateAvailableWidth(_ width: CGFloat) {
        guard width > 0, abs(width - availableWidth) > 1 else { return }
        availableWidth = width
    }

    // MARK: - Persistence

    private func save() {
        let rootData = root.flatMap { try? JSONEncoder().encode($0) }
        UserDefaults.standard.set(rootData, forKey: defaultsKey + ".root")
        UserDefaults.standard.set(splitRatios.mapValues { Double($0) }, forKey: defaultsKey + ".splitRatios")
        let floatingData = try? JSONEncoder().encode(Array(floatingPanels))
        UserDefaults.standard.set(floatingData, forKey: defaultsKey + ".floatingPanels")
        UserDefaults.standard.set(isLocked, forKey: defaultsKey + ".isLocked")
    }

    private func load() {
        if let rootData = UserDefaults.standard.data(forKey: defaultsKey + ".root"),
           let decoded = try? JSONDecoder().decode(LayoutNode.self, from: rootData) {
            root = decoded
        } else if let legacyData = UserDefaults.standard.data(forKey: defaultsKey + ".rows"),
                  let legacyRows = try? JSONDecoder().decode([LegacyRow].self, from: legacyData) {
            root = migrateLegacyRows(legacyRows)
        }
        if let ratios = UserDefaults.standard.dictionary(forKey: defaultsKey + ".splitRatios") as? [String: Double] {
            splitRatios = ratios
        }
        if let floatingData = UserDefaults.standard.data(forKey: defaultsKey + ".floatingPanels"),
           let decoded = try? JSONDecoder().decode([WorkspacePanelKind].self, from: floatingData) {
            floatingPanels = Set(decoded)
        }
        isLocked = UserDefaults.standard.bool(forKey: defaultsKey + ".isLocked")
    }

    /// Convert the old rows/columns/stacks grid into a binary tree.
    /// Each row becomes a vertical split of its columns; each column becomes a
    /// horizontal split of its panel stacks; each stack becomes a vertical
    /// split of its panels. Ratios default to 0.5.
    private func migrateLegacyRows(_ rows: [LegacyRow]) -> LayoutNode? {
        guard !rows.isEmpty else { return nil }
        func buildStack(_ panels: [WorkspacePanelKind]) -> LayoutNode {
            guard !panels.isEmpty else { return .leaf(.appLauncher) }
            if panels.count == 1 { return .leaf(panels[0]) }
            return .stack(panels)
        }
        func buildColumn(_ column: LegacyColumn) -> LayoutNode {
            let stacks = column.panels.map { buildStack([$0]) }
            guard let first = stacks.first else { return .leaf(.appLauncher) }
            return stacks.dropFirst().reduce(first) { acc, next in
                .split(axis: .vertical, ratio: 0.5, first: acc, second: next)
            }
        }
        func buildRow(_ row: LegacyRow) -> LayoutNode {
            guard !row.columns.isEmpty else { return .leaf(.appLauncher) }
            let columns = row.columns.map(buildColumn)
            return columns.reduce(columns[0]) { acc, next in
                .split(axis: .horizontal, ratio: 0.5, first: acc, second: next)
            }
        }
        let treeRows = rows.map(buildRow)
        return treeRows.reduce(treeRows[0]) { acc, next in
            .split(axis: .vertical, ratio: 0.5, first: acc, second: next)
        }
    }
}

// MARK: - Layout Path Helpers

private extension LayoutPath {
    var ratioKey: String {
        steps.map { $0.rawValue }.joined(separator: "/")
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by tools/agents to request that the main UI open or focus a
    /// top-level workspace panel. The notification's `object` should be the
    /// `WorkspacePanelKind` to open.
    static let openWorkspacePanel = Notification.Name("com.woodseedigi.swiftmaestro.openWorkspacePanel")
    /// Posted when a workspace panel that is already open should be brought to
    /// the front of the window stack. The notification's `object` should be the
    /// `WorkspacePanelKind` to focus.
    static let bringWorkspacePanelToFront = Notification.Name("com.woodseedigi.swiftmaestro.bringWorkspacePanelToFront")
    /// Posted when a detached agent-chat window that is already open should be
    /// brought to the front. The notification's `object` should be the agent's
    /// `UUID`.
    static let bringAgentChatToFront = Notification.Name("com.woodseedigi.swiftmaestro.bringAgentChatToFront")

    /// Posted by the Agents panel to request the "new project agent" sheet.
    static let newAgentRequested = Notification.Name("com.woodseedigi.swiftmaestro.newAgentRequested")
    /// Posted by the Agents panel to request the "change category" sheet for an
    /// agent. The notification's `object` is the `AgentRecord`.
    static let agentCategoryRequested = Notification.Name("com.woodseedigi.swiftmaestro.agentCategoryRequested")
    /// Posted by the Agents panel to request removing an agent. The
    /// notification's `object` is the `AgentRecord`.
    static let removeAgentRequested = Notification.Name("com.woodseedigi.swiftmaestro.removeAgentRequested")
}
