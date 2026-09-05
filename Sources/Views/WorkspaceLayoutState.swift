import SwiftUI

// MARK: - Canvas Grid

/// The workspace grid: 24 columns × 16 rows with gutters. Tiles occupy whole
/// cell spans, so tiles can never overlap — empty cells are the visible
/// "space available" for new panels. Grid units scale with the window, so
/// resizing the window re-flows tiles proportionally.
///
/// The grid was doubled from 12×8 to 24×16 so small resize/drag adjustments
/// actually free up cells instead of leaving a tile parked across the same
/// coarse span. This eliminates the "panels weren't touching but still
/// overlapped/swap" bug caused by quantization.
enum CanvasGrid {
    static let cols = 24
    static let rows = 16
    static let gap: Double = 10

    static func cellSize(in canvas: CGSize) -> CGSize {
        CGSize(
            width: (Double(canvas.width) - gap * Double(cols + 1)) / Double(cols),
            height: (Double(canvas.height) - gap * Double(rows + 1)) / Double(rows)
        )
    }

    /// Pixel frame of a cell span within a canvas.
    static func frame(col: Int, row: Int, colSpan: Int, rowSpan: Int, in canvas: CGSize) -> CGRect {
        let cell = cellSize(in: canvas)
        let x = gap + Double(col) * (cell.width + gap)
        let y = gap + Double(row) * (cell.height + gap)
        let w = Double(colSpan) * cell.width + Double(colSpan - 1) * gap
        let h = Double(rowSpan) * cell.height + Double(rowSpan - 1) * gap
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The cell containing a canvas-space point (clamped into the grid).
    static func cell(at point: CGPoint, in canvas: CGSize) -> (col: Int, row: Int) {
        let cell = cellSize(in: canvas)
        let col = Int((Double(point.x) - gap) / (cell.width + gap))
        let row = Int((Double(point.y) - gap) / (cell.height + gap))
        return (min(max(0, col), cols - 1), min(max(0, row), rows - 1))
    }

    /// Whether two cell spans intersect.
    static func spansIntersect(_ a: (col: Int, row: Int, colSpan: Int, rowSpan: Int),
                               _ b: (col: Int, row: Int, colSpan: Int, rowSpan: Int)) -> Bool {
        a.col < b.col + b.colSpan && b.col < a.col + a.colSpan
            && a.row < b.row + b.rowSpan && b.row < a.row + a.rowSpan
    }
}

// MARK: - Layout Algorithms

/// Hyprland-inspired layout algorithms for automatic tile arrangement.
/// Each algorithm computes new `col/row/colSpan/rowSpan` values for every tile
/// on the canvas. `freeform` preserves the current manual placement.
enum WorkspaceLayoutAlgorithm: String, Codable, CaseIterable, Sendable {
    /// Current behavior — manual drag-and-drop placement.
    case freeform
    /// First tile (lowest z) occupies the left ~60% as the "master" panel;
    /// remaining tiles stack vertically in the right ~40%.
    case masterStack
    /// Focused tile (highest z) fills the entire canvas (12×8); all other
    /// tiles are hidden behind it. Clicking a tile raises it to focus.
    case monocle
    /// Tiles are arranged in a balanced grid, distributing them evenly across
    /// the canvas — like pseudo-tiling for floating windows.
    case grid

    var displayName: String {
        switch self {
        case .freeform: return "Freeform"
        case .masterStack: return "Master Stack"
        case .monocle: return "Monocle"
        case .grid: return "Grid"
        }
    }

    var icon: String {
        switch self {
        case .freeform: return "rectangle.split.2x2"
        case .masterStack: return "rectangle.righthalf.filled"
        case .monocle: return "rectangle.expand.vertical"
        case .grid: return "square.grid.3x3"
        }
    }
}

// MARK: - Canvas Tile Model

/// One tile on the workspace canvas grid. `kinds` holds a tab stack (dropping
/// a tile onto another's center merges them). Position is in GRID CELLS —
/// pixels are derived per canvas size, so tiles scale with the window and can
/// never overlap.
struct CanvasTile: Identifiable, Codable, Hashable, Sendable {
    /// The main window's canvas. Other UUIDs = secondary canvas windows.
    static let mainCanvasID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var id: UUID = UUID()
    var kinds: [WorkspacePanelKind]
    var col: Int
    var row: Int
    var colSpan: Int
    var rowSpan: Int
    var z: Int
    /// Which canvas window this tile lives on (main window by default).
    var canvasID: UUID = CanvasTile.mainCanvasID

    var cellSpan: (col: Int, row: Int, colSpan: Int, rowSpan: Int) { (col, row, colSpan, rowSpan) }

    /// Pixel frame within a canvas of the given size.
    func frame(in canvas: CGSize) -> CGRect {
        CanvasGrid.frame(col: col, row: row, colSpan: colSpan, rowSpan: rowSpan, in: canvas)
    }

    /// Smallest sane span (a kind with a wide minimum column gets more cells).
    /// These thresholds are tuned for the 24×16 grid; they correspond to the
    /// previous 12×8 values doubled so the same pixel widths are enforced.
    var minColSpan: Int {
        let minWidth = kinds.map(\.minColumnWidth).max() ?? 280
        return minWidth > 560 ? 10 : minWidth > 420 ? 8 : minWidth > 200 ? 6 : 4
    }
    var minRowSpan: Int { 4 }

    /// Memberwise init (explicit because the custom decoder suppresses the
    /// synthesized one).
    init(id: UUID = UUID(), kinds: [WorkspacePanelKind], col: Int, row: Int,
         colSpan: Int, rowSpan: Int, z: Int, canvasID: UUID = CanvasTile.mainCanvasID) {
        self.id = id
        self.kinds = kinds
        self.col = col
        self.row = row
        self.colSpan = colSpan
        self.rowSpan = rowSpan
        self.z = z
        self.canvasID = canvasID
    }

    // Custom Codable: the legacy pixel keys (x/y/w/h) are decode-only inputs
    // for migration — they're never written, so encoding is explicit.
    private enum CodingKeys: String, CodingKey {
        case id, kinds, col, row, colSpan, rowSpan, z, canvasID
        case x, y, w, h  // legacy pixel model (decode-only)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kinds, forKey: .kinds)
        try c.encode(col, forKey: .col)
        try c.encode(row, forKey: .row)
        try c.encode(colSpan, forKey: .colSpan)
        try c.encode(rowSpan, forKey: .rowSpan)
        try c.encode(z, forKey: .z)
        try c.encode(canvasID, forKey: .canvasID)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kinds = try c.decode([WorkspacePanelKind].self, forKey: .kinds)
        z = try c.decode(Int.self, forKey: .z)
        canvasID = try c.decodeIfPresent(UUID.self, forKey: .canvasID) ?? Self.mainCanvasID

        if let decodedCol = try c.decodeIfPresent(Int.self, forKey: .col) {
            col = decodedCol
            row = try c.decode(Int.self, forKey: .row)
            colSpan = try c.decode(Int.self, forKey: .colSpan)
            rowSpan = try c.decode(Int.self, forKey: .rowSpan)
        } else {
            // Quantize the legacy pixel frame (nominal 1400×900 canvas) into cells.
            let px = try c.decodeIfPresent(Double.self, forKey: .x) ?? 16
            let py = try c.decodeIfPresent(Double.self, forKey: .y) ?? 16
            let pw = try c.decodeIfPresent(Double.self, forKey: .w) ?? 560
            let ph = try c.decodeIfPresent(Double.self, forKey: .h) ?? 440
            let nominal = CGSize(width: 1_400, height: 900)
            let originCell = CanvasGrid.cell(at: CGPoint(x: px, y: py), in: nominal)
            col = originCell.col
            row = originCell.row
            colSpan = min(CanvasGrid.cols - col, max(6, Int((pw / 1400.0 * Double(CanvasGrid.cols)).rounded())))
            rowSpan = min(CanvasGrid.rows - row, max(4, Int((ph / 900.0 * Double(CanvasGrid.rows)).rounded())))
        }
    }
}

/// A secondary canvas window (the main window's canvas is implicit).
struct CanvasWindowInfo: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date = Date()
}


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
    /// MapQuest — free web map panel (no paid API during beta).
    case mapquest
    case photos
    /// Stocks — watchlist with live quotes + sparklines (Yahoo Finance, no API key).
    case stocks
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
    /// "Swift Apps" item instead. The UUID lets multiple independent Terminal
    /// panels coexist in the workspace, each with its own tab/pane state.
    case terminal(UUID)

    /// Launcher/settings template for Terminal. Every tap creates a fresh
    /// `.terminal(UUID())` instance; this constant is only used for display,
    /// enablement, and theming (all of which share the "terminal" key).
    static let terminalApp: WorkspacePanelKind = .terminal(UUID())
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
    /// HTML Builder — live HTML/CSS editor with transparent PNG export
    /// and WYSIWYG preview (overlays, title cards, lower thirds, etc.).
    case htmlBuilder
    /// Backup management panel — Restic-backed offsite/local backups.
    case backup
    /// Voice Notes — record-first voice memos: audio streams to disk
    /// immediately, transcription follows as a background process.
    case voiceNotes
    /// Blocky — blockchain wallet lookup and transaction tracing (BTC/ETH).
    case blocky
    /// Pomodoro — focus/break timer with menu-bar counter (pomarchy-style).
    case pomodoro
    /// MediaPlayer — retro-styled (BTOP+) media player with AVKit playback,
    /// spectrum visualization, playlist queue, and volume control.
    case mediaPlayer

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
        case .mapquest: return "map.fill"
        case .photos: return "photo.stack"
        case .stocks: return "chart.line.uptrend.xyaxis"
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
        case .htmlBuilder: return "rectangle.dashed"
        case .backup: return "arrow.triangle.2.circlepath"
        case .voiceNotes: return "mic.circle"
        case .blocky: return "link.circle"
        case .pomodoro: return "timer"
        case .mediaPlayer: return "play.circle"
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
        case .mapquest: return "mapquest"
        case .photos: return "photos"
        case .stocks: return "stocks"
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
        case .htmlBuilder: return "overlayBuilder"
        case .backup: return "backup"
        case .voiceNotes: return "voiceNotes"
        case .blocky: return "blocky"
        case .pomodoro: return "pomodoro"
        case .mediaPlayer: return "mediaPlayer"
        }
    }

    /// Static display name for non-agent panels. Agent chat panels resolve
    /// their name from `WorkspaceStore` at the view layer instead, since the
    /// name can change (rename) independently of this identity.
    var staticDisplayName: String? {
        switch self {
        case .agentChat: return nil
        case .notesMD: return String(localized: "Notes.md")
        case .appleNotes: return String(localized: "Apple Notes")
        case .calendar: return String(localized: "Calendar")
        case .reminders: return String(localized: "Reminders")
        case .contacts: return String(localized: "Contacts")
        case .canvas: return String(localized: "Excalidraw")
        case .kanban: return String(localized: "Kanban")
        case .numbers: return String(localized: "Numbers")
        case .maps: return String(localized: "Maps")
        case .mapquest: return String(localized: "MapQuest")
        case .photos: return String(localized: "Photos")
        case .stocks: return String(localized: "Stocky")
        case .mail: return String(localized: "Mail")
        case .whatsapp: return String(localized: "WhatsApp")
        case .discord: return String(localized: "Discord")
        case .plugin: return nil
        case .terminal: return String(localized: "Terminal")
        case .busMonitor: return String(localized: "Bus Monitor")
        case .audioControl: return String(localized: "Audio Control")
        case .tethering: return String(localized: "Cameras")
        case .streamIngest: return String(localized: "Stream Ingest")
        case .broadcast: return String(localized: "Broadcast")
        case .streamMixer: return String(localized: "Stream Mixer")
        case .ndiBrowser: return String(localized: "NDI Browser")
        case .colorAdjustments: return String(localized: "Color Adjustments")
        case .scenes: return String(localized: "Scenes")
        case .agents: return String(localized: "Agents")
        case .appLauncher: return String(localized: "Apps")
        case .webBrowser: return String(localized: "SwiftBrowser")
        case .damBrowser: return String(localized: "MaestroDAM")
        case .maestroDocs: return String(localized: "MaestroDocs")
        case .maestroBooks: return String(localized: "MaestroBooks")
        case .maestroDB: return String(localized: "MaestroDB")
        case .htmlBuilder: return String(localized: "SwiftWeaver")
        case .backup: return String(localized: "Backup")
        case .voiceNotes: return String(localized: "Voice Notes")
        case .blocky: return String(localized: "Blocky")
        case .pomodoro: return String(localized: "Pomodoro")
        case .mediaPlayer: return String(localized: "Media Player")
        }
    }

    /// Minimum comfortable column width. Agent chat panels host their own
    /// nested Plans/Tasks/Terminal sub-panels (see `ChatView`'s own
    /// `ResizablePanelHost`), so squeezing one down to a generic panel's
    /// minimum would squish that inner layout unreadable — the exact bug this
    /// value exists to prevent. Simpler single-content panels can go narrower.
    var minColumnWidth: CGFloat {
        switch self {
        // Chats host nested Plans/Tasks sub-panels, so they want room — but
        // 560 was a hard floor that stopped users resizing the chat smaller
        // on the canvas grid. 380 keeps it readable; go narrower by choice.
        case .agentChat: return 380
        // Agents and Apps are simple icon+label lists — they stay usable as
        // narrow rails, so they get a lower floor (4 grid cells ≈ 300 px on a
        // 1440p canvas with the 24×16 grid) than content-heavy panels.
        case .agents, .appLauncher: return 160
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
        case .mapquest: return "mapquest"
        case .photos: return "photos"
        case .stocks: return "stocks"
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
        case .htmlBuilder: return "overlayBuilder"
        case .backup: return "backup"
        case .voiceNotes: return "voiceNotes"
        case .blocky: return "blocky"
        case .pomodoro: return "pomodoro"
        case .mediaPlayer: return "mediaPlayer"
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

    /// Legacy binary tiling tree — retained ONLY to migrate saved layouts into
    /// canvas tiles on first launch after the canvas cutover. No longer drives
    /// any UI; do not add new references.
    private var root: LayoutNode?

    /// The workspace canvas: free-positioned tiles with absolute frames.
    /// Empty space is just where no tile is; opening a panel uses free space
    /// instead of re-dividing existing tiles. Tiles are scoped per canvas
    /// window (`CanvasTile.canvasID`) — the main window plus any secondary
    /// canvas windows (e.g. a group of panels on a second monitor).
    private(set) var canvasTiles: [CanvasTile] = []

    /// Secondary canvas windows (the main window's canvas is implicit and not
    /// listed). Persisted so canvas windows reopen on launch.
    private(set) var canvasWindows: [CanvasWindowInfo] = []
    /// Runtime-only set of canvas windows currently open on screen (secondary
    /// canvases only; never persisted). Drives the Window menu's reopen list —
    /// closing a canvas window used to strand its tiles invisibly until the
    /// next app restart because nothing tracked that it was gone.
    private(set) var openCanvasWindowIDs: Set<UUID> = []

    /// Per-canvas measured size (runtime only — not persisted).
    private var canvasSizes: [UUID: CGSize] = [:]

    /// Panels currently open in their own floating window rather than docked
    /// on the canvas. Panels opened with Option (nil zone) float immediately.
    private(set) var floatingPanels: Set<WorkspacePanelKind> = []

    /// When `true`, the workspace layout is locked and panels cannot be dragged
    /// or dropped. The lock toggle lives in the main toolbar.
    var isLocked = false

    /// The active layout algorithm for the workspace. When changed, the canvas
    /// tiles are rearranged according to the selected algorithm.
    var layoutAlgorithm: WorkspaceLayoutAlgorithm = .freeform {
        didSet {
            guard layoutAlgorithm != oldValue, !isLoading else { return }
            applyLayoutAlgorithm(layoutAlgorithm)
            save()
        }
    }

    /// Suppresses layout algorithm side effects during load.
    private var isLoading = false

    /// The currently focused tile in monocle mode. When set, the focused tile
    /// fills the canvas and all others are hidden.
    private(set) var focusedTileID: UUID?

    /// Persisted split ratio per split node — legacy tree state, unused by the
    /// canvas. Retained so a pre-cutover install's data round-trips harmlessly.
    private var splitRatios: [String: Double] = [:]

    /// The most recently measured size of the workspace canvas area. Used for
    /// new-tile placement and to clamp tiles on window resize.
    /// (Main window's canvas — secondary canvases report via `canvasSizes`.)
    var canvasSize: CGSize {
        get { canvasSizes[CanvasTile.mainCanvasID] ?? CGSize(width: 1_200, height: 900) }
        set { canvasSizes[CanvasTile.mainCanvasID] = newValue }
    }

    /// Measured size of a specific canvas window (default until it reports).
    func canvasSize(for canvasID: UUID) -> CGSize {
        canvasSizes[canvasID] ?? CGSize(width: 1_200, height: 900)
    }

    /// Back-compat shim for older callers that only know the width.
    var availableWidth: CGFloat {
        get { canvasSize.width }
        set { canvasSize.width = max(1, newValue) }
    }

    private let defaultsKey = "SwiftMaestro.WorkspaceLayout"
    private var gridVersionKey: String { defaultsKey + ".gridVersion" }
    private let currentGridVersion = 2
    private static let minRatio: Double = 0.1
    private static let maxRatio: Double = 0.9

    init() {
        load()
    }

    // MARK: - Queries

    func isOpen(_ kind: WorkspacePanelKind) -> Bool {
        floatingPanels.contains(kind) || canvasTiles.contains { $0.kinds.contains(kind) }
    }

    func isFloating(_ kind: WorkspacePanelKind) -> Bool {
        floatingPanels.contains(kind)
    }

    /// All panels currently docked on the canvas, front-to-back (z order),
    /// then floating panels.
    var allOpenPanels: [WorkspacePanelKind] {
        canvasTiles.sorted { $0.z > $1.z }.flatMap(\.kinds) + floatingPanels
    }

    /// Like `isOpen`, but treats `.terminal` as a wildcard: returns `true` if
    /// ANY Terminal panel is currently open. Used by the launcher so the
    /// Terminal row shows its "open" dot even though each Terminal panel has a
    /// unique instance UUID.
    func isOpenOrAnyTerminal(_ kind: WorkspacePanelKind) -> Bool {
        if case .terminal = kind {
            return allOpenPanels.contains(where: { panel in
                if case .terminal = panel { return true }
                return false
            })
        }
        return isOpen(kind)
    }

    /// Whether the canvas holds more than one tile.
    var hasMultipleTiles: Bool {
        canvasTiles.count > 1
    }

    // MARK: - Open / close / float

    enum OpenResult {
        case alreadyOpen
        /// The very first panel opened into an empty workspace.
        case dockedDirectly
        /// Opened as a new floating window.
        case floated
    }

    /// Open a panel. By default it lands in the largest free canvas area.
    /// Pass a nil zone (Option) to float it as its own window instead.
    @discardableResult
    func open(_ kind: WorkspacePanelKind, zone: TilingDropZone? = .right) -> OpenResult {
        guard !isOpen(kind) else { return .alreadyOpen }

        guard zone != nil else {
            floatingPanels.insert(kind)
            save()
            return .floated
        }

        if let tile = newTile(kind) {
            canvasTiles.append(tile)
            save()
            return .dockedDirectly
        }
        // No room on the canvas — float as its own window instead of
        // overlapping (hard rule). Callers open the floating window.
        floatingPanels.insert(kind)
        save()
        return .floated
    }

    /// Ensure the navigation "chrome" — the Agents navigator panel with the
    /// Apps launcher beneath it — exists on the canvas, with the navigator's
    /// chat taking the main area. Called at launch; a saved layout keeps its
    /// frames untouched (only missing tiles are added).
    func ensureChromeLayout(navigatorID: UUID) {
        var changed = false

        if !canvasContains(.agents) {
            canvasTiles.append(CanvasTile(
                kinds: [.agents], col: 0, row: 0, colSpan: 6, rowSpan: 10, z: nextZ()
            ))
            changed = true
        }
        if !canvasContains(.appLauncher) {
            canvasTiles.append(CanvasTile(
                kinds: [.appLauncher], col: 0, row: 10, colSpan: 6, rowSpan: 6, z: nextZ()
            ))
            changed = true
        }
        let chat = WorkspacePanelKind.agentChat(navigatorID)
        if !canvasContains(chat) {
            canvasTiles.append(CanvasTile(
                kinds: [chat], col: 6, row: 0, colSpan: 18, rowSpan: 16, z: nextZ()
            ))
            changed = true
        }
        if changed { save() }
    }

    /// Dock a floating panel onto the canvas (largest free area).
    /// The `zone` parameter is accepted for call-site compatibility; free
    /// placement supersedes it. No room → the panel stays floating.
    func dock(_ kind: WorkspacePanelKind, zone: TilingDropZone = .bottom) {
        guard floatingPanels.remove(kind) != nil else { return }
        if let tile = newTile(kind) {
            canvasTiles.append(tile)
        } else {
            floatingPanels.insert(kind)
        }
        save()
    }

    /// Dock a panel onto the canvas — used by the background drop target when
    /// a floating panel is dropped onto empty canvas space.
    /// No room → the panel stays floating.
    func dockAsRoot(_ kind: WorkspacePanelKind) {
        floatingPanels.remove(kind)
        if let tile = newTile(kind) {
            canvasTiles.append(tile)
        } else {
            floatingPanels.insert(kind)
        }
        save()
    }

    /// Dock a floating panel at a specific canvas location (drop position
    /// quantizes to the containing cell). Falls back to the best free
    /// placement when the drop cell is occupied; keeps the panel floating
    /// when the canvas has no room at all — never overlaps.
    func dockAt(_ kind: WorkspacePanelKind, origin: CGPoint, canvasID: UUID = CanvasTile.mainCanvasID) {
        floatingPanels.remove(kind)
        let preferred = preferredSpan(for: kind)
        var tile = CanvasTile(kinds: [kind], col: 0, row: 0,
                              colSpan: preferred.colSpan, rowSpan: preferred.rowSpan,
                              z: nextZ(), canvasID: canvasID)
        makeRoomIfNeeded(minColSpan: tile.minColSpan, minRowSpan: tile.minRowSpan, canvasID: canvasID)
        let cell = CanvasGrid.cell(at: origin, in: canvasSize(for: canvasID))
        let dropCol = min(cell.col, CanvasGrid.cols - tile.colSpan)
        let dropRow = min(cell.row, CanvasGrid.rows - tile.rowSpan)
        if let spot = nearestFreeCell(for: tile.cellSpan, canvasID: canvasID, preferring: (dropCol, dropRow)) {
            tile.col = spot.col
            tile.row = spot.row
        } else if let spot = bestPlacement(preferred: preferred,
                                           minColSpan: tile.minColSpan,
                                           minRowSpan: tile.minRowSpan,
                                           canvasID: canvasID) {
            tile.col = spot.col
            tile.row = spot.row
            tile.colSpan = spot.colSpan
            tile.rowSpan = spot.rowSpan
        } else {
            floatingPanels.insert(kind)
            save()
            return
        }
        canvasTiles.append(tile)
        save()
    }

    /// Pop a docked panel back out into its own floating window.
    func float(_ kind: WorkspacePanelKind) {
        removeFromCanvas(kind)
        floatingPanels.insert(kind)
        save()
    }

    /// Close a panel, whether docked or floating. Does not dismiss its window.
    func close(_ kind: WorkspacePanelKind) {
        if floatingPanels.remove(kind) != nil {
            save()
            return
        }
        removeFromCanvas(kind)
        save()
    }

    // MARK: - Canvas Tile Operations

    func canvasTile(id: UUID) -> CanvasTile? {
        canvasTiles.first { $0.id == id }
    }

    func canvasTile(containing kind: WorkspacePanelKind) -> CanvasTile? {
        canvasTiles.first { $0.kinds.contains(kind) }
    }

    func canvasContains(_ kind: WorkspacePanelKind) -> Bool {
        canvasTiles.contains { $0.kinds.contains(kind) }
    }

    /// Tiles on one canvas window, back-to-front (paint order).
    func tiles(for canvasID: UUID) -> [CanvasTile] {
        canvasTiles.filter { $0.canvasID == canvasID }.sorted { $0.z < $1.z }
    }

    // MARK: - Canvas windows

    /// Create a secondary canvas window (host it with the "canvas-window"
    /// WindowGroup scene and openWindow).
    @discardableResult
    func createCanvasWindow(named name: String? = nil) -> CanvasWindowInfo {
        let info = CanvasWindowInfo(
            id: UUID(),
            name: name ?? "Canvas \(canvasWindows.count + 2)"
        )
        canvasWindows.append(info)
        save()
        return info
    }

    /// Remove a secondary canvas window; its tiles move back to the main canvas.
    func removeCanvasWindow(id: UUID) {
        guard id != CanvasTile.mainCanvasID else { return }
        canvasWindows.removeAll { $0.id == id }
        openCanvasWindowIDs.remove(id)
        for idx in canvasTiles.indices where canvasTiles[idx].canvasID == id {
            canvasTiles[idx].canvasID = CanvasTile.mainCanvasID
        }
        save()
    }

    /// Track which secondary canvas windows are actually on screen. Tiles on a
    /// CLOSED canvas stay assigned to it (they reappear when it reopens), so
    /// this set is how the Window menu can offer to reopen a closed canvas
    /// instead of leaving its tiles stranded until the next launch.
    func markCanvasWindowOpen(_ id: UUID) {
        guard id != CanvasTile.mainCanvasID else { return }
        openCanvasWindowIDs.insert(id)
    }

    func markCanvasWindowClosed(_ id: UUID) {
        guard id != CanvasTile.mainCanvasID else { return }
        openCanvasWindowIDs.remove(id)
    }

    /// Move a tile to another canvas window, placed in that canvas's best
    /// free area. No room there → the tile stays where it is.
    func moveTileToCanvas(_ tileID: UUID, canvasID: UUID) {
        guard let idx = canvasTiles.firstIndex(where: { $0.id == tileID }) else { return }
        let tile = canvasTiles[idx]
        let preferred = (colSpan: tile.colSpan, rowSpan: tile.rowSpan)
        guard let spot = bestPlacement(preferred: preferred,
                                       minColSpan: tile.minColSpan,
                                       minRowSpan: tile.minRowSpan,
                                       canvasID: canvasID) else { return }
        canvasTiles[idx].canvasID = canvasID
        canvasTiles[idx].col = spot.col
        canvasTiles[idx].row = spot.row
        canvasTiles[idx].colSpan = spot.colSpan
        canvasTiles[idx].rowSpan = spot.rowSpan
        canvasTiles[idx].z = nextZ()
        save()
    }

    private func nextZ() -> Int {
        (canvasTiles.map(\.z).max() ?? 0) + 1
    }

    /// Preferred grid span for a panel kind (chats get a big area, chrome is
    /// narrow, utility panels are compact). Values are tuned for the 24×16 grid.
    private func preferredSpan(for kind: WorkspacePanelKind) -> (colSpan: Int, rowSpan: Int) {
        switch kind {
        case .agentChat: return (10, 16)
        case .agents, .appLauncher: return (6, 8)
        case .terminal: return (8, 8)
        case .webBrowser, .damBrowser, .maestroDocs, .maestroDB: return (10, 12)
        case .htmlBuilder: return (12, 16)
        case .backup, .voiceNotes: return (8, 12)
        default: return (8, 8)
        }
    }

    /// New tile for a panel placed in the best free area of `canvasID`.
    /// Returns nil when the canvas genuinely has no room even at the tile's
    /// minimum span — callers then keep/return the panel as a floating window
    /// instead of overlapping (HARD RULE: docked tiles never overlap).
    private func newTile(_ kind: WorkspacePanelKind, canvasID: UUID = CanvasTile.mainCanvasID) -> CanvasTile? {
        let preferred = preferredSpan(for: kind)
        var tile = CanvasTile(kinds: [kind], col: 0, row: 0,
                              colSpan: preferred.colSpan, rowSpan: preferred.rowSpan,
                              z: nextZ(), canvasID: canvasID)
        makeRoomIfNeeded(minColSpan: tile.minColSpan, minRowSpan: tile.minRowSpan, canvasID: canvasID)
        guard let spot = bestPlacement(preferred: preferred,
                                       minColSpan: tile.minColSpan,
                                       minRowSpan: tile.minRowSpan,
                                       canvasID: canvasID) else { return nil }
        tile.col = spot.col
        tile.row = spot.row
        tile.colSpan = spot.colSpan
        tile.rowSpan = spot.rowSpan
        return tile
    }

    /// First free placement for a span, scanning top-left → bottom-right.
    /// Returns nil when nothing fits — NEVER a fallback occupied cell.
    /// HARD RULE: docked tiles may not overlap; only floating windows may.
    private func firstFreeCell(colSpan: Int, rowSpan: Int, canvasID: UUID) -> (col: Int, row: Int)? {
        guard colSpan >= 1, rowSpan >= 1,
              colSpan <= CanvasGrid.cols, rowSpan <= CanvasGrid.rows else { return nil }
        let localTiles = canvasTiles.filter { $0.canvasID == canvasID }
        for row in 0...(CanvasGrid.rows - rowSpan) {
            for col in 0...(CanvasGrid.cols - colSpan) {
                let candidate = (col: col, row: row, colSpan: colSpan, rowSpan: rowSpan)
                if !localTiles.contains(where: { CanvasGrid.spansIntersect($0.cellSpan, candidate) }) {
                    return (col, row)
                }
            }
        }
        return nil
    }

    /// The largest empty rectangle on the canvas (cell units), scanning
    /// top-left → bottom-right; ties go to the earliest origin. Only
    /// rectangles at least minColSpan × minRowSpan qualify. This is what lets
    /// a new panel land in a vacant pocket (e.g. bottom-right) with its span
    /// clamped to fit instead of demanding the full preferred span or nothing.
    private func largestFreeRect(minColSpan: Int, minRowSpan: Int, canvasID: UUID) -> (col: Int, row: Int, colSpan: Int, rowSpan: Int)? {
        let localTiles = canvasTiles.filter { $0.canvasID == canvasID }
        var free = [[Bool]](repeating: [Bool](repeating: true, count: CanvasGrid.cols), count: CanvasGrid.rows)
        for tile in localTiles {
            for r in max(0, tile.row)..<min(tile.row + tile.rowSpan, CanvasGrid.rows) {
                for c in max(0, tile.col)..<min(tile.col + tile.colSpan, CanvasGrid.cols) {
                    free[r][c] = false
                }
            }
        }
        var best: (col: Int, row: Int, colSpan: Int, rowSpan: Int)?
        var bestArea = 0
        for row in 0..<CanvasGrid.rows {
            for col in 0..<CanvasGrid.cols where free[row][col] {
                // Maximal rectangle anchored at (col,row): grow downward while
                // shrinking width to each row's free run; score every step.
                var width = 0
                while col + width < CanvasGrid.cols && free[row][col + width] { width += 1 }
                var height = 0
                var r = row
                while r < CanvasGrid.rows, width > 0 {
                    var run = 0
                    while col + run < CanvasGrid.cols && free[r][col + run] { run += 1 }
                    width = min(width, run)
                    if width == 0 { break }
                    height += 1
                    let area = width * height
                    if width >= minColSpan, height >= minRowSpan, area > bestArea {
                        bestArea = area
                        best = (col, row, width, height)
                    }
                    r += 1
                }
            }
        }
        return best
    }

    /// Best free placement for a tile: the full preferred span at the
    /// top-left-most free cell when it fits; otherwise the largest free
    /// rectangle anywhere on the canvas with the span clamped into it (never
    /// below the minimum). Nil only when nothing ≥ the minimum fits — the
    /// caller then floats the panel instead of overlapping.
    private func bestPlacement(preferred: (colSpan: Int, rowSpan: Int),
                               minColSpan: Int, minRowSpan: Int,
                               canvasID: UUID) -> (col: Int, row: Int, colSpan: Int, rowSpan: Int)? {
        if let spot = firstFreeCell(colSpan: preferred.colSpan, rowSpan: preferred.rowSpan, canvasID: canvasID) {
            return (spot.col, spot.row, preferred.colSpan, preferred.rowSpan)
        }
        guard let rect = largestFreeRect(minColSpan: minColSpan, minRowSpan: minRowSpan, canvasID: canvasID) else {
            return nil
        }
        return (rect.col, rect.row,
                max(minColSpan, min(preferred.colSpan, rect.colSpan)),
                max(minRowSpan, min(preferred.rowSpan, rect.rowSpan)))
    }

    /// When the grid has no free rectangle at least minColSpan × minRowSpan,
    /// shrink the largest existing tile (by area, preferring its wider axis)
    /// until one appears. Bounded; if every tile is at its minimum and the
    /// grid is genuinely full, gives up — the caller floats the new panel
    /// instead of overlapping. ("Bump-to-move": new panels push existing ones
    /// smaller, never on top of each other.)
    ///
    /// Agent chat tiles are shrunk preferentially — they're the "master" that
    /// should make room for new panels, rather than shrinking sidebar chrome
    /// (Agents, Apps) that the user expects to stay stable.
    private func makeRoomIfNeeded(minColSpan: Int, minRowSpan: Int, canvasID: UUID) {
        guard largestFreeRect(minColSpan: minColSpan, minRowSpan: minRowSpan, canvasID: canvasID) == nil else { return }

        for _ in 0..<(CanvasGrid.cols * 2) {
            var bestIdx: Int?
            var bestArea = 0

            // Prefer shrinking agent chat tiles — they're the flexible "master"
            // area that should give way for new panels. Shrink by the needed
            // amount in one shot rather than 1-col-at-a-time.
            let neededCols = minColSpan
            for idx in canvasTiles.indices where canvasTiles[idx].canvasID == canvasID {
                let tile = canvasTiles[idx]
                let isAgentChat = tile.kinds.contains(where: {
                    if case .agentChat = $0 { return true } else { return false }
                })
                if isAgentChat, tile.colSpan - neededCols >= tile.minColSpan {
                    bestIdx = idx
                    bestArea = Int.max
                    break
                }
            }

            // Fallback: shrink the largest tile by area.
            if bestIdx == nil {
                for idx in canvasTiles.indices where canvasTiles[idx].canvasID == canvasID {
                    let tile = canvasTiles[idx]
                    let area = tile.colSpan * tile.rowSpan
                    if (tile.colSpan > tile.minColSpan || tile.rowSpan > tile.minRowSpan) && area > bestArea {
                        bestIdx = idx
                        bestArea = area
                    }
                }
            }

            guard let idx = bestIdx else { break }

            // Shrink the agent chat by the full needed amount in one step;
            // other tiles shrink 1 col/row at a time.
            let isAgentChat = canvasTiles[idx].kinds.contains(where: {
                if case .agentChat = $0 { return true } else { return false }
            })
            if isAgentChat, canvasTiles[idx].colSpan - neededCols >= canvasTiles[idx].minColSpan {
                canvasTiles[idx].colSpan -= neededCols
            } else if canvasTiles[idx].colSpan > canvasTiles[idx].minColSpan {
                canvasTiles[idx].colSpan -= 1
            } else if canvasTiles[idx].rowSpan > canvasTiles[idx].minRowSpan {
                canvasTiles[idx].rowSpan -= 1
            }

            if largestFreeRect(minColSpan: minColSpan, minRowSpan: minRowSpan, canvasID: canvasID) != nil {
                break
            }
        }
        save()
    }

    /// Nearest free cell to a preferred position (used for drop placement).
    private func nearestFreeCell(for span: (col: Int, row: Int, colSpan: Int, rowSpan: Int),
                                 canvasID: UUID,
                                 preferring: (col: Int, row: Int)) -> (col: Int, row: Int)? {
        let localTiles = canvasTiles.filter { $0.canvasID == canvasID }
        func isFree(_ col: Int, _ row: Int) -> Bool {
            guard col >= 0, row >= 0, col + span.colSpan <= CanvasGrid.cols, row + span.rowSpan <= CanvasGrid.rows else { return false }
            let candidate = (col: col, row: row, colSpan: span.colSpan, rowSpan: span.rowSpan)
            return !localTiles.contains(where: { CanvasGrid.spansIntersect($0.cellSpan, candidate) })
        }
        if isFree(preferring.col, preferring.row) { return preferring }
        // Spiral out from the preferred cell, nearest first.
        for radius in 1...max(CanvasGrid.cols, CanvasGrid.rows) {
            var best: (col: Int, row: Int, dist: Int)?
            for dcol in -radius...radius {
                for drow in -radius...radius where max(abs(dcol), abs(drow)) == radius {
                    let col = preferring.col + dcol, row = preferring.row + drow
                    if isFree(col, row) {
                        let dist = abs(dcol) + abs(drow)
                        if best == nil || dist < best!.dist { best = (col, row, dist) }
                    }
                }
            }
            if let best { return (best.col, best.row) }
        }
        return nil
    }

    /// Move a tile to a new cell origin (drop commit — the view renders the
    /// live pixel offset during the drag; only the final cell lands here).
    func moveTile(_ id: UUID, toCol col: Int, row: Int) {
        guard let idx = canvasTiles.firstIndex(where: { $0.id == id }) else { return }
        canvasTiles[idx].col = min(max(0, col), CanvasGrid.cols - canvasTiles[idx].colSpan)
        canvasTiles[idx].row = min(max(0, row), CanvasGrid.rows - canvasTiles[idx].rowSpan)
        save()
    }

    /// Resize a tile to a new span. Clamped to its minimum, the grid bounds —
    /// and its NEIGHBOURS: growth stops at the first occupied cell so a resize
    /// can never swallow another docked tile (hard no-overlap rule).
    func resizeTileSpan(_ id: UUID, colSpan: Int, rowSpan: Int) {
        guard let idx = canvasTiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = canvasTiles[idx]
        let others = canvasTiles.filter { $0.canvasID == tile.canvasID && $0.id != id }
        var newColSpan = min(max(tile.minColSpan, colSpan), CanvasGrid.cols - tile.col)
        var newRowSpan = min(max(tile.minRowSpan, rowSpan), CanvasGrid.rows - tile.row)
        // Width growth checks side neighbours against the CURRENT height…
        while newColSpan > tile.minColSpan,
              others.contains(where: { CanvasGrid.spansIntersect($0.cellSpan, (tile.col, tile.row, newColSpan, tile.rowSpan)) }) {
            newColSpan -= 1
        }
        // …then height growth checks below neighbours against the FINAL width.
        while newRowSpan > tile.minRowSpan,
              others.contains(where: { CanvasGrid.spansIntersect($0.cellSpan, (tile.col, tile.row, newColSpan, newRowSpan)) }) {
            newRowSpan -= 1
        }
        canvasTiles[idx].colSpan = newColSpan
        canvasTiles[idx].rowSpan = newRowSpan
        save()
    }

    /// Resize a tile from its top-leading corner: both the origin and span may
    /// change. The span is first clamped to the new origin and minimum size,
    /// then shrunk until it no longer overlaps any neighbour.
    func resizeTileFromTopLeading(_ id: UUID, toCol col: Int, row: Int, colSpan: Int, rowSpan: Int) {
        guard let idx = canvasTiles.firstIndex(where: { $0.id == id }) else { return }
        let tile = canvasTiles[idx]
        let others = canvasTiles.filter { $0.canvasID == tile.canvasID && $0.id != id }

        var newCol = min(max(0, col), CanvasGrid.cols - tile.minColSpan)
        var newRow = min(max(0, row), CanvasGrid.rows - tile.minRowSpan)
        var newColSpan = min(max(tile.minColSpan, colSpan), tile.col + tile.colSpan - newCol)
        var newRowSpan = min(max(tile.minRowSpan, rowSpan), tile.row + tile.rowSpan - newRow)

        // Shrink from the top-left until the new span doesn't overlap anyone.
        while newColSpan > tile.minColSpan,
              others.contains(where: { CanvasGrid.spansIntersect($0.cellSpan, (newCol, newRow, newColSpan, newRowSpan)) }) {
            newColSpan -= 1
        }
        while newRowSpan > tile.minRowSpan,
              others.contains(where: { CanvasGrid.spansIntersect($0.cellSpan, (newCol, newRow, newColSpan, newRowSpan)) }) {
            newRowSpan -= 1
        }

        // If shrinking the span created a gap, pull the origin back toward the
        // original bottom-right corner so the tile stays contiguous.
        newCol = min(newCol, tile.col + tile.colSpan - newColSpan)
        newRow = min(newRow, tile.row + tile.rowSpan - newRowSpan)

        canvasTiles[idx].col = newCol
        canvasTiles[idx].row = newRow
        canvasTiles[idx].colSpan = newColSpan
        canvasTiles[idx].rowSpan = newRowSpan
        save()
    }

    func bringTileToFront(_ id: UUID) {
        guard let idx = canvasTiles.firstIndex(where: { $0.id == id }) else { return }
        let top = canvasTiles.map(\.z).max() ?? 0
        guard canvasTiles[idx].z < top else { return }
        canvasTiles[idx].z = top + 1
        save()
    }

    /// Merge one tile into another as a tab stack (center drop).
    func stackTile(_ sourceID: UUID, onto targetID: UUID) {
        guard sourceID != targetID,
              let sourceIdx = canvasTiles.firstIndex(where: { $0.id == sourceID }),
              let targetIdx = canvasTiles.firstIndex(where: { $0.id == targetID }) else { return }
        let kinds = canvasTiles[sourceIdx].kinds.filter { !canvasTiles[targetIdx].kinds.contains($0) }
        canvasTiles[targetIdx].kinds.append(contentsOf: kinds)
        canvasTiles[targetIdx].z = nextZ()
        canvasTiles.remove(at: sourceIdx)
        save()
    }

    /// Swap two tiles' cell *positions* only, keeping each tile's own span.
    /// This prevents the jumbled layouts caused by swapping different-sized
    /// spans. The swap is validated: if either tile would overlap a third tile
    /// or leave the grid bounds, the swap is cancelled and nothing moves.
    func swapTiles(_ a: UUID, _ b: UUID) {
        guard a != b,
              let ai = canvasTiles.firstIndex(where: { $0.id == a }),
              let bi = canvasTiles.firstIndex(where: { $0.id == b }) else { return }
        let aTile = canvasTiles[ai]
        let bTile = canvasTiles[bi]
        let others = canvasTiles.filter { $0.canvasID == aTile.canvasID && $0.id != a && $0.id != b }

        // Try position swap, keeping original spans.
        canvasTiles[ai].col = bTile.col
        canvasTiles[ai].row = bTile.row
        canvasTiles[bi].col = aTile.col
        canvasTiles[bi].row = aTile.row

        let newA = canvasTiles[ai].cellSpan
        let newB = canvasTiles[bi].cellSpan
        let aInBounds = newA.col + newA.colSpan <= CanvasGrid.cols && newA.row + newA.rowSpan <= CanvasGrid.rows
        let bInBounds = newB.col + newB.colSpan <= CanvasGrid.cols && newB.row + newB.rowSpan <= CanvasGrid.rows
        let overlaps = others.contains(where: {
            CanvasGrid.spansIntersect($0.cellSpan, newA) || CanvasGrid.spansIntersect($0.cellSpan, newB)
        })

        if !aInBounds || !bInBounds || overlaps {
            // Revert: leave both tiles where they started.
            canvasTiles[ai].col = aTile.col
            canvasTiles[ai].row = aTile.row
            canvasTiles[bi].col = bTile.col
            canvasTiles[bi].row = bTile.row
            return
        }

        canvasTiles[ai].z = nextZ()
        save()
    }

    /// Pull one panel kind out of a stacked tile into its own tile. No free
    /// spot → the kind stays stacked (never an overlapping detach).
    func detachKind(_ kind: WorkspacePanelKind, from tileID: UUID) {
        guard let idx = canvasTiles.firstIndex(where: { $0.id == tileID }),
              canvasTiles[idx].kinds.count > 1,
              canvasTiles[idx].kinds.contains(kind) else { return }
        let source = canvasTiles[idx]
        let preferred = (colSpan: max(source.minColSpan, min(4, source.colSpan)),
                         rowSpan: max(source.minRowSpan, min(4, source.rowSpan)))
        let probe = CanvasTile(kinds: [kind], col: 0, row: 0,
                               colSpan: preferred.colSpan, rowSpan: preferred.rowSpan,
                               z: 0, canvasID: source.canvasID)
        guard let spot = bestPlacement(preferred: preferred,
                                       minColSpan: probe.minColSpan,
                                       minRowSpan: probe.minRowSpan,
                                       canvasID: source.canvasID) else { return }
        canvasTiles[idx].kinds.removeAll { $0 == kind }
        canvasTiles.append(CanvasTile(kinds: [kind], col: spot.col, row: spot.row,
                                      colSpan: spot.colSpan, rowSpan: spot.rowSpan,
                                      z: nextZ(), canvasID: source.canvasID))
        save()
    }

    /// Snap a tile to a half (or full) grid area — edge-of-canvas drop.
    func snapTileToCanvasEdge(_ tileID: UUID, edge: TilingDropZone) {
        guard let idx = canvasTiles.firstIndex(where: { $0.id == tileID }) else { return }
        let cols = CanvasGrid.cols, rows = CanvasGrid.rows
        switch edge {
        case .left:
            canvasTiles[idx].col = 0; canvasTiles[idx].row = 0
            canvasTiles[idx].colSpan = cols / 2; canvasTiles[idx].rowSpan = rows
        case .right:
            canvasTiles[idx].col = cols / 2; canvasTiles[idx].row = 0
            canvasTiles[idx].colSpan = cols / 2; canvasTiles[idx].rowSpan = rows
        case .top:
            canvasTiles[idx].col = 0; canvasTiles[idx].row = 0
            canvasTiles[idx].colSpan = cols; canvasTiles[idx].rowSpan = rows / 2
        case .bottom:
            canvasTiles[idx].col = 0; canvasTiles[idx].row = rows / 2
            canvasTiles[idx].colSpan = cols; canvasTiles[idx].rowSpan = rows / 2
        case .center:
            canvasTiles[idx].col = 0; canvasTiles[idx].row = 0
            canvasTiles[idx].colSpan = cols; canvasTiles[idx].rowSpan = rows
        }
        canvasTiles[idx].z = nextZ()
        save()
    }

    // MARK: - Default Layout

    /// Rearrange the main canvas's tiles into the canonical layout:
    /// Agents over Apps launcher in the left column, navigator chat center,
    /// everything else in the right column. Stale agent-chat tiles (whose
    /// agent no longer exists) are dropped, and a navigator chat tile is
    /// guaranteed. Other canvas windows are untouched.
    func resetToDefaultLayout() {
        let canvasID = CanvasTile.mainCanvasID
        guard let workspace = MaestroTools.workspace else { return }
        let navigatorID = workspace.navigator.id

        // Self-healing: drop agent-chat tiles that point to deleted or stale agents.
        canvasTiles.removeAll { tile in
            tile.kinds.contains { kind in
                if case .agentChat(let id) = kind {
                    return workspace.agent(id: id) == nil
                }
                return false
            }
        }

        var agentsTile: CanvasTile?
        var launcherTile: CanvasTile?
        var chatTiles: [CanvasTile] = []
        var otherTiles: [CanvasTile] = []
        var staleTileIDs: [UUID] = []

        for tile in canvasTiles where tile.canvasID == canvasID {
            if tile.kinds.contains(.agents) { agentsTile = tile }
            else if tile.kinds.contains(.appLauncher) { launcherTile = tile }
            else if tile.kinds.contains(where: { kind in
                if case .agentChat(let id) = kind {
                    // Keep only chat tiles whose agent still exists. The
                    // navigator chat is always valid; project/searcher chats
                    // are kept if their agent survived load.
                    return workspace.agent(id: id) != nil
                }
                return false
            }) {
                chatTiles.append(tile)
            } else {
                otherTiles.append(tile)
            }
        }

        // Drop any chat tile whose agent no longer exists so we never show
        // "Agent Not Found" after a reset.
        for tile in chatTiles {
            let hasMissingAgent = tile.kinds.contains(where: { kind in
                if case .agentChat(let id) = kind { return workspace.agent(id: id) == nil }
                return false
            })
            if hasMissingAgent { staleTileIDs.append(tile.id) }
        }
        if !staleTileIDs.isEmpty {
            canvasTiles.removeAll { staleTileIDs.contains($0.id) }
            chatTiles.removeAll { staleTileIDs.contains($0.id) }
        }

        // Ensure the navigator chat exists in the layout.
        let hasNavigatorChat = chatTiles.contains { tile in
            tile.kinds.contains(where: { kind in
                if case .agentChat(let id) = kind { return id == navigatorID }
                return false
            })
        }
        if !hasNavigatorChat {
            let navigatorChat = CanvasTile(
                kinds: [.agentChat(navigatorID)],
                col: 0, row: 0, colSpan: 12, rowSpan: 16, z: nextZ(),
                canvasID: canvasID
            )
            canvasTiles.append(navigatorChat)
            chatTiles.append(navigatorChat)
        }

        // If no valid chat tile remains, open the navigator chat so the workspace isn't empty.
        if chatTiles.isEmpty, let navigatorID = MaestroTools.workspace?.navigator.id {
            let chatTile = CanvasTile(
                kinds: [.agentChat(navigatorID)],
                col: 0, row: 0, colSpan: 5, rowSpan: 8,
                z: nextZ(), canvasID: canvasID
            )
            canvasTiles.append(chatTile)
            chatTiles.append(chatTile)
        }

        let hasChrome = agentsTile != nil || launcherTile != nil
        let chromeCols = hasChrome ? 6 : 0
        let rightCols = otherTiles.isEmpty ? 0 : 6
        let centerCols = CanvasGrid.cols - chromeCols - rightCols

        var zCounter = 0
        func place(_ tile: CanvasTile, col: Int, row: Int, colSpan: Int, rowSpan: Int) {
            guard let idx = canvasTiles.firstIndex(where: { $0.id == tile.id }) else { return }
            zCounter += 1
            canvasTiles[idx].col = col
            canvasTiles[idx].row = row
            canvasTiles[idx].colSpan = colSpan
            canvasTiles[idx].rowSpan = rowSpan
            canvasTiles[idx].z = zCounter
        }

        if let agentsTile, let launcherTile {
            place(agentsTile, col: 0, row: 0, colSpan: chromeCols, rowSpan: 10)
            place(launcherTile, col: 0, row: 10, colSpan: chromeCols, rowSpan: 6)
        } else if let agentsTile {
            place(agentsTile, col: 0, row: 0, colSpan: chromeCols, rowSpan: 16)
        } else if let launcherTile {
            place(launcherTile, col: 0, row: 0, colSpan: chromeCols, rowSpan: 16)
        }

        for (i, chat) in chatTiles.enumerated() {
            let each = centerCols / max(1, chatTiles.count)
            place(chat, col: chromeCols + i * each, row: 0, colSpan: each, rowSpan: 16)
        }

        for (i, tile) in otherTiles.enumerated() {
            let each = max(1, CanvasGrid.rows / otherTiles.count)
            let row = min(CanvasGrid.rows - each, i * each)
            place(tile, col: CanvasGrid.cols - rightCols, row: row, colSpan: rightCols, rowSpan: each)
        }

        save()
    }

    /// Restore a layout preset: replace the current canvas tiles and floating
    /// panels with the snapshot stored in the preset. Used by
    /// `WorkspaceLayoutPresetStore.recall()`. The snapshot is run through the
    /// overlap repair so a preset captured in a corrupt era can never
    /// reintroduce overlapping tiles.
    func restorePreset(_ preset: WorkspaceLayoutPreset) {
        canvasTiles = preset.canvasTiles
        floatingPanels.removeAll()
        for kind in preset.floatingPanels {
            floatingPanels.insert(kind)
        }
        isLocked = preset.isLocked
        let repair = repairOverlaps()
        floatingPanels.formUnion(repair.floated)
        save()
    }

    // MARK: - Layout Algorithms

    /// Cycle to the next layout algorithm and apply it.
    func cycleLayoutAlgorithm() {
        let all = WorkspaceLayoutAlgorithm.allCases
        guard let idx = all.firstIndex(of: layoutAlgorithm) else { return }
        layoutAlgorithm = all[(idx + 1) % all.count]
    }

    /// Focus a tile in monocle mode — raise it to fill the canvas.
    func focusTile(_ tileID: UUID) {
        guard layoutAlgorithm == .monocle else { return }
        focusedTileID = tileID
        // Raise the focused tile's z-order above all others.
        if let idx = canvasTiles.firstIndex(where: { $0.id == tileID }) {
            let maxZ = canvasTiles.map(\.z).max() ?? 0
            canvasTiles[idx].z = maxZ + 1
            canvasTiles[idx].col = 0
            canvasTiles[idx].row = 0
            canvasTiles[idx].colSpan = CanvasGrid.cols
            canvasTiles[idx].rowSpan = CanvasGrid.rows
            // Hide all others.
            for i in canvasTiles.indices where canvasTiles[i].id != tileID && canvasTiles[i].canvasID == CanvasTile.mainCanvasID {
                canvasTiles[i].colSpan = 0
                canvasTiles[i].rowSpan = 0
            }
        }
        save()
    }

    /// Apply the given layout algorithm to all tiles on the main canvas.
    private func applyLayoutAlgorithm(_ algorithm: WorkspaceLayoutAlgorithm) {
        switch algorithm {
        case .freeform:
            // No-op — preserve current manual positions.
            focusedTileID = nil
        case .masterStack:
            focusedTileID = nil
            arrangeAsMasterStack()
        case .monocle:
            // Focus the highest-z tile (most recently used).
            let mainTiles = canvasTiles.filter { $0.canvasID == CanvasTile.mainCanvasID }
            focusedTileID = mainTiles.max(by: { $0.z < $1.z })?.id
            arrangeAsMonocle()
        case .grid:
            focusedTileID = nil
            arrangeAsGrid()
        }
    }

    /// Master-stack: the tile with the lowest z-order (most behind) becomes the
    /// "master" and occupies the left ~60% of the canvas. All other tiles stack
    /// vertically in the right ~40%.
    private func arrangeAsMasterStack() {
        var tiles = canvasTiles.filter { $0.canvasID == CanvasTile.mainCanvasID }
            .sorted { $0.z < $1.z }
        guard !tiles.isEmpty else { return }

        let masterCols = 14   // ~58% of 24 columns
        let stackCols = 10    // ~42%
        let stackX = masterCols

        // Master tile gets the full left side.
        if let idx = canvasTiles.firstIndex(where: { $0.id == tiles[0].id }) {
            canvasTiles[idx].col = 0
            canvasTiles[idx].row = 0
            canvasTiles[idx].colSpan = masterCols
            canvasTiles[idx].rowSpan = CanvasGrid.rows
        }

        // Stack remaining tiles vertically on the right.
        let stackTiles = Array(tiles.dropFirst())
        let rowsPerTile = max(CanvasGrid.rows / max(1, stackTiles.count), 2)

        for (i, tile) in stackTiles.enumerated() {
            guard let idx = canvasTiles.firstIndex(where: { $0.id == tile.id }) else { continue }
            let row = i * rowsPerTile
            let remaining = CanvasGrid.rows - row
            canvasTiles[idx].col = stackX
            canvasTiles[idx].row = row
            canvasTiles[idx].colSpan = stackCols
            canvasTiles[idx].rowSpan = min(rowsPerTile, remaining)
        }
    }

    /// Monocle: the focused tile (highest z-order) fills the entire canvas.
    /// All other tiles are hidden (set to 0 span) — they remain in the array
    /// so they can be restored when switching back to another layout.
    private func arrangeAsMonocle() {
        var tiles = canvasTiles.filter { $0.canvasID == CanvasTile.mainCanvasID }
            .sorted { $0.z > $1.z }
        guard !tiles.isEmpty else { return }

        // Focused tile gets full canvas.
        if let idx = canvasTiles.firstIndex(where: { $0.id == tiles[0].id }) {
            canvasTiles[idx].col = 0
            canvasTiles[idx].row = 0
            canvasTiles[idx].colSpan = CanvasGrid.cols
            canvasTiles[idx].rowSpan = CanvasGrid.rows
        }

        // Hide all other tiles (0 span = invisible but preserved).
        for tile in tiles.dropFirst() {
            guard let idx = canvasTiles.firstIndex(where: { $0.id == tile.id }) else { continue }
            canvasTiles[idx].colSpan = 0
            canvasTiles[idx].rowSpan = 0
        }
    }

    /// Grid: distribute tiles evenly across the canvas in a balanced grid.
    /// Computes rows × cols that best fits the tile count, then assigns each
    /// tile an equal-sized cell.
    private func arrangeAsGrid() {
        let tiles = canvasTiles.filter { $0.canvasID == CanvasTile.mainCanvasID }
            .sorted { $0.z < $1.z }
        guard !tiles.isEmpty else { return }

        let n = tiles.count
        // Find the most square grid that fits n tiles.
        let gridCols = Int(ceil(sqrt(Double(n))))
        let gridRows = Int(ceil(Double(n) / Double(gridCols)))

        let cellColSpan = CanvasGrid.cols / gridCols
        let cellRowSpan = CanvasGrid.rows / gridRows

        for (i, tile) in tiles.enumerated() {
            guard let idx = canvasTiles.firstIndex(where: { $0.id == tile.id }) else { continue }
            let col = (i % gridCols) * cellColSpan
            let row = (i / gridCols) * cellRowSpan
            canvasTiles[idx].col = col
            canvasTiles[idx].row = row
            canvasTiles[idx].colSpan = cellColSpan
            canvasTiles[idx].rowSpan = cellRowSpan
        }
    }

    /// Records a canvas window's measured size (grid is size-independent —
    /// tiles keep their cell spans and re-flow proportionally).
    func clampTilesToCanvas(_ size: CGSize, canvasID: UUID = CanvasTile.mainCanvasID) {
        canvasSizes[canvasID] = size
    }

    /// Enforce the grid invariant after decoding/migration: clamp spans into
    /// bounds, then resolve every overlap. Escalation per tile, in order:
    /// 1. MOVE to the nearest free cell at the current span.
    /// 2. SHRINK toward the grid minimum until a free spot exists (the grid
    ///    can be over-committed — e.g. a full-height sidebar plus a
    ///    full-width chat leave zero free cells, so moving alone can never
    ///    resolve the overlap; this was the fossil-overlap bug).
    /// 3. FLOAT the panel — docked tiles never overlap (hard rule).
    /// Front-most tiles (highest z) claim their cells first.
    ///
    /// Returns the panel kinds that had to be floated plus whether any tile
    /// changed, so callers can merge floats into `floatingPanels` and persist
    /// the repaired state. (Pixel-era saved data can decode into intersecting
    /// spans; grid-era data is normally already clean.)
    @discardableResult
    private func repairOverlaps() -> (floated: [WorkspacePanelKind], changed: Bool) {
        var floated: [WorkspacePanelKind] = []
        var changed = false
        let canvasIDs = Set(canvasTiles.map(\.canvasID))
        for canvasID in canvasIDs {
            // Front-most tiles claim their cells first.
            var placed: [(col: Int, row: Int, colSpan: Int, rowSpan: Int)] = []
            let ordered = canvasTiles.filter { $0.canvasID == canvasID }.sorted(by: { $0.z > $1.z })
            for tile in ordered {
                guard let idx = canvasTiles.firstIndex(where: { $0.id == tile.id }) else { continue }

                // Zero-span tiles are intentionally hidden by the monocle
                // layout — leave them untouched. In any other layout a zero
                // span is corrupt, so it falls through to the clamp (min 2)
                // and the tile becomes visible again.
                let isZeroSpan = canvasTiles[idx].colSpan <= 0 || canvasTiles[idx].rowSpan <= 0
                if isZeroSpan && layoutAlgorithm == .monocle { continue }

                // Clamp into grid bounds first.
                let before = canvasTiles[idx].cellSpan
                canvasTiles[idx].colSpan = min(max(4, canvasTiles[idx].colSpan), CanvasGrid.cols)
                canvasTiles[idx].rowSpan = min(max(4, canvasTiles[idx].rowSpan), CanvasGrid.rows)
                canvasTiles[idx].col = min(max(0, canvasTiles[idx].col), CanvasGrid.cols - canvasTiles[idx].colSpan)
                canvasTiles[idx].row = min(max(0, canvasTiles[idx].row), CanvasGrid.rows - canvasTiles[idx].rowSpan)
                if canvasTiles[idx].cellSpan != before { changed = true }

                let span = canvasTiles[idx].cellSpan
                guard placed.contains(where: { CanvasGrid.spansIntersect($0, span) }) else {
                    placed.append(span)
                    continue
                }

                // 1) MOVE: find the nearest free spot among already-placed tiles.
                if let spot = nearestFreeCellExcluding(span: (span.colSpan, span.rowSpan),
                                                       canvasID: canvasID,
                                                       placed: placed,
                                                       preferring: (span.col, span.row)) {
                    canvasTiles[idx].col = spot.col
                    canvasTiles[idx].row = spot.row
                    placed.append(canvasTiles[idx].cellSpan)
                    changed = true
                    continue
                }

                // 2) SHRINK: no free cell exists at the current span (grid is
                // over-committed). Reduce the span — largest dimension first —
                // until it fits somewhere. A cramped docked panel beats an
                // overlapping one; the user can resize or reset after.
                var resolved = false
                var candidate = (colSpan: span.colSpan, rowSpan: span.rowSpan)
                shrinkLoop: while candidate.colSpan > 2 || candidate.rowSpan > 2 {
                    if candidate.colSpan >= candidate.rowSpan, candidate.colSpan > 2 {
                        candidate.colSpan -= 1
                    } else {
                        candidate.rowSpan -= 1
                    }
                    if let spot = nearestFreeCellExcluding(span: candidate,
                                                           canvasID: canvasID,
                                                           placed: placed,
                                                           preferring: (span.col, span.row)) {
                        canvasTiles[idx].col = spot.col
                        canvasTiles[idx].row = spot.row
                        canvasTiles[idx].colSpan = candidate.colSpan
                        canvasTiles[idx].rowSpan = candidate.rowSpan
                        placed.append(canvasTiles[idx].cellSpan)
                        changed = true
                        resolved = true
                        break shrinkLoop
                    }
                }
                if resolved { continue }

                // 3) FLOAT: absolutely no room, even at minimum size — pop the
                // panel out into a floating window instead of overlapping.
                floated.append(contentsOf: canvasTiles[idx].kinds)
                canvasTiles.remove(at: idx)
                changed = true
            }
        }
        return (floated, changed)
    }

    /// Nearest free cell given an explicit already-placed list (repair pass),
    /// spiraling out from the preferred position.
    private func nearestFreeCellExcluding(span: (colSpan: Int, rowSpan: Int),
                                          canvasID: UUID,
                                          placed: [(col: Int, row: Int, colSpan: Int, rowSpan: Int)],
                                          preferring: (col: Int, row: Int)) -> (col: Int, row: Int)? {
        func isFree(_ col: Int, _ row: Int) -> Bool {
            guard col >= 0, row >= 0,
                  col + span.colSpan <= CanvasGrid.cols,
                  row + span.rowSpan <= CanvasGrid.rows else { return false }
            let candidate = (col: col, row: row, colSpan: span.colSpan, rowSpan: span.rowSpan)
            return !placed.contains { CanvasGrid.spansIntersect($0, candidate) }
        }
        if isFree(preferring.col, preferring.row) { return preferring }
        for radius in 1...max(CanvasGrid.cols, CanvasGrid.rows) {
            var best: (col: Int, row: Int, dist: Int)?
            for dcol in -radius...radius {
                for drow in -radius...radius where max(abs(dcol), abs(drow)) == radius {
                    let col = preferring.col + dcol, row = preferring.row + drow
                    if isFree(col, row) {
                        let dist = abs(dcol) + abs(drow)
                        if best == nil || dist < best!.dist { best = (col, row, dist) }
                    }
                }
            }
            if let best { return (best.col, best.row) }
        }
        return nil
    }

    /// Remove a panel kind from the canvas; a tile that becomes empty disappears.
    private func removeFromCanvas(_ kind: WorkspacePanelKind) {
        guard let idx = canvasTiles.firstIndex(where: { $0.kinds.contains(kind) }) else { return }
        canvasTiles[idx].kinds.removeAll { $0 == kind }
        if canvasTiles[idx].kinds.isEmpty {
            canvasTiles.remove(at: idx)
        }
    }

    // MARK: - Sizing

    func updateAvailableWidth(_ width: CGFloat) {
        guard width > 0, abs(width - availableWidth) > 1 else { return }
        availableWidth = width
    }

    // MARK: - Persistence

    private func save() {
        let tilesData = try? JSONEncoder().encode(canvasTiles)
        UserDefaults.standard.set(tilesData, forKey: defaultsKey + ".canvasTiles")
        let windowsData = try? JSONEncoder().encode(canvasWindows)
        UserDefaults.standard.set(windowsData, forKey: defaultsKey + ".canvasWindows")
        let floatingData = try? JSONEncoder().encode(Array(floatingPanels))
        UserDefaults.standard.set(floatingData, forKey: defaultsKey + ".floatingPanels")
        UserDefaults.standard.set(isLocked, forKey: defaultsKey + ".isLocked")
        UserDefaults.standard.set(layoutAlgorithm.rawValue, forKey: defaultsKey + ".layoutAlgorithm")
        // Note: the legacy tree blob (".root", ".splitRatios") is left in place
        // untouched — backup-before-destructive; nothing reads it anymore.
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if let tilesData = UserDefaults.standard.data(forKey: defaultsKey + ".canvasTiles"),
           let decoded = try? JSONDecoder().decode([CanvasTile].self, from: tilesData) {
            canvasTiles = decoded
            migrateGridResolutionIfNeeded()
        } else {
            migrateTreeToCanvas()
        }
        // Decode the layout algorithm BEFORE repairing: repairOverlaps treats
        // zero-span tiles as intentionally hidden only in monocle mode, so it
        // needs the persisted algorithm in place first. (The didSet side
        // effects are suppressed by isLoading.)
        if let algoRaw = UserDefaults.standard.string(forKey: defaultsKey + ".layoutAlgorithm"),
           let algo = WorkspaceLayoutAlgorithm(rawValue: algoRaw) {
            layoutAlgorithm = algo
        }
        // Enforce the grid invariant: migrations from the pixel-era model can
        // decode into intersecting spans. De-overlap deterministically. Panels
        // that can't fit even at minimum size are floated — merged into
        // floatingPanels after its decode below (the decode would otherwise
        // overwrite the repair's floats).
        let repair = repairOverlaps()
        // One-time migration: replace the old hardcoded canvas-ID UUID that was
        // mistakenly used as an agent ID in .agentChat() tiles with the real
        // navigator agent UUID.
        migrateAgentUUIDs()
        // One-time canonical layout for installs landing on the grid with a
        // legacy (pixel or tree) layout: Agents over Apps left, chat(s)
        // center, everything else right. The flag makes it happen exactly once.
        let gridLayoutKey = defaultsKey + ".gridLayoutV1.done"
        if !UserDefaults.standard.bool(forKey: gridLayoutKey) {
            resetToDefaultLayout()
            UserDefaults.standard.set(true, forKey: gridLayoutKey)
        }
        if let windowsData = UserDefaults.standard.data(forKey: defaultsKey + ".canvasWindows"),
           let decoded = try? JSONDecoder().decode([CanvasWindowInfo].self, from: windowsData) {
            canvasWindows = decoded
        }
        if let ratios = UserDefaults.standard.dictionary(forKey: defaultsKey + ".splitRatios") as? [String: Double] {
            splitRatios = ratios
        }
        if let floatingData = UserDefaults.standard.data(forKey: defaultsKey + ".floatingPanels"),
           let decoded = try? JSONDecoder().decode([WorkspacePanelKind].self, from: floatingData) {
            floatingPanels = Set(decoded)
        }
        floatingPanels.formUnion(repair.floated)
        isLocked = UserDefaults.standard.bool(forKey: defaultsKey + ".isLocked")
        // Persist the repaired layout so the corrupt state doesn't come back
        // on the next launch.
        if repair.changed { save() }
    }

    /// One-time migration: scale layouts saved on the old 12×8 grid up to the
    /// current 24×16 grid. Doubles every tile's col/row/colSpan/rowSpan.
    private func migrateGridResolutionIfNeeded() {
        let savedVersion = UserDefaults.standard.integer(forKey: gridVersionKey)
        guard savedVersion < currentGridVersion else { return }
        for idx in canvasTiles.indices {
            canvasTiles[idx].col *= 2
            canvasTiles[idx].row *= 2
            canvasTiles[idx].colSpan *= 2
            canvasTiles[idx].rowSpan *= 2
        }
        UserDefaults.standard.set(currentGridVersion, forKey: gridVersionKey)
        save()
    }

    /// One-time migration: replace the old hardcoded canvas-ID UUID that was
    /// mistakenly used as an agent ID in .agentChat() tiles with the real
    /// navigator agent UUID. Runs on every load — idempotent.
    private func migrateAgentUUIDs() {
        let badID = CanvasTile.mainCanvasID  // 00000000-0000-0000-0000-000000000001
        let navigatorID = WorkspaceStore().navigator.id
        guard navigatorID != badID else { return }
        var changed = false
        for idx in canvasTiles.indices {
            for kindIdx in canvasTiles[idx].kinds.indices {
                if case .agentChat(let id) = canvasTiles[idx].kinds[kindIdx], id == badID {
                    canvasTiles[idx].kinds[kindIdx] = .agentChat(navigatorID)
                    changed = true
                }
            }
        }
        if changed { save() }
    }

    /// One-time migration: flatten the legacy binary tree into canvas tiles,
    /// preserving approximate relative positions by walking splits with their
    /// ratios over a nominal canvas. Stacks (tab groups) stay stacked.
    private func migrateTreeToCanvas() {
        // Load the tree (or its legacy rows form) purely as migration input.
        var tree: LayoutNode?
        if let rootData = UserDefaults.standard.data(forKey: defaultsKey + ".root"),
           let decoded = try? JSONDecoder().decode(LayoutNode.self, from: rootData) {
            tree = decoded
        } else if let legacyData = UserDefaults.standard.data(forKey: defaultsKey + ".rows"),
                  let legacyRows = try? JSONDecoder().decode([LegacyRow].self, from: legacyData) {
            tree = migrateLegacyRows(legacyRows)
        }
        guard let tree else { return }

        var tiles: [CanvasTile] = []
        var zCounter = 0

        // Walk the tree over the 12x8 grid: horizontal splits divide columns,
        // vertical splits divide rows, stacks stay stacked.
        func walk(_ node: LayoutNode, col: Int, row: Int, colSpan: Int, rowSpan: Int) {
            switch node {
            case .leaf(let kind):
                zCounter += 1
                tiles.append(CanvasTile(kinds: [kind], col: col, row: row,
                                        colSpan: max(1, colSpan), rowSpan: max(1, rowSpan),
                                        z: zCounter))
            case .stack(let kinds):
                zCounter += 1
                tiles.append(CanvasTile(kinds: kinds, col: col, row: row,
                                        colSpan: max(1, colSpan), rowSpan: max(1, rowSpan),
                                        z: zCounter))
            case .split(let axis, let ratio, let first, let second):
                let clamped = min(0.9, max(0.1, ratio))
                if axis == .horizontal {
                    let c1 = max(1, Int((Double(colSpan) * clamped).rounded()))
                    if colSpan - c1 < 1 {
                        walk(.stack(first.allPanels() + second.allPanels()), col: col, row: row, colSpan: colSpan, rowSpan: rowSpan)
                    } else {
                        walk(first, col: col, row: row, colSpan: c1, rowSpan: rowSpan)
                        walk(second, col: col + c1, row: row, colSpan: colSpan - c1, rowSpan: rowSpan)
                    }
                } else {
                    let r1 = max(1, Int((Double(rowSpan) * clamped).rounded()))
                    if rowSpan - r1 < 1 {
                        walk(.stack(first.allPanels() + second.allPanels()), col: col, row: row, colSpan: colSpan, rowSpan: rowSpan)
                    } else {
                        walk(first, col: col, row: row, colSpan: colSpan, rowSpan: r1)
                        walk(second, col: col, row: row + r1, colSpan: colSpan, rowSpan: rowSpan - r1)
                    }
                }
            }
        }
        walk(tree, col: 0, row: 0, colSpan: CanvasGrid.cols, rowSpan: CanvasGrid.rows)
        canvasTiles = tiles
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
