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
    /// RSS/Atom feed reader with YouTube watch-history sync.
    case rssReader
    /// Publish — track draft content across SwiftMaestro apps and publish to feeds.
    case publish
    /// Game Studio — DOS-style text adventure authoring and player.
    case storyGame

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
        case .rssReader: return "dot.radiowaves.up.forward"
        case .publish: return "newspaper"
        case .storyGame: return "gamecontroller"
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
        case .rssReader: return "rssReader"
        case .publish: return "publish"
        case .storyGame: return "storyGame"
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
        case .rssReader: return String(localized: "Reader")
        case .publish: return String(localized: "Publish")
        case .storyGame: return String(localized: "Game Studio")
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
        case .rssReader: return "rssReader"
        case .publish: return "publish"
        case .storyGame: return "storyGame"
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
    ///
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

    /// Panels currently open in their own floating window rather than docked
    /// on the canvas. Panels opened with Option (nil zone) float immediately.
    private(set) var floatingPanels: Set<WorkspacePanelKind> = []

    /// When `true`, the workspace layout is locked and panels cannot be dragged
    /// or dropped. The lock toggle lives in the main toolbar.
    var isLocked = false

    private let defaultsKey = "SwiftMaestro.WorkspaceLayout"
    private var gridVersionKey: String { defaultsKey + ".gridVersion" }
    private let currentGridVersion = 2
    private static let minRatio: Double = 0.1
    private static let maxRatio: Double = 0.9

    /// Debug builds start with a blank workspace every launch so heavy panels
    /// (MaestroDAM, storage health scans, etc.) don't auto-restore and overload
    /// the system while debugging. Release builds still remember the last layout.
    #if DEBUG
    private let isDebugNoPersistence = true
    #else
    private let isDebugNoPersistence = false
    #endif

    init() {
        if isDebugNoPersistence {
            // Start empty; AgentsWindowView.onAppear opens the default chrome.
        } else {
            load()
            migrateCanvasTilesToFloatingPanels()
        }
    }

    /// One-time cutover from the canvas grid to floating windows: every panel
    /// a persisted layout had docked becomes its own window instead. Without
    /// this, `isOpen` would report a docked panel as open while no window
    /// exists to show for it.
    private func migrateCanvasTilesToFloatingPanels() {
        guard !canvasTiles.isEmpty else { return }
        for tile in canvasTiles { floatingPanels.formUnion(tile.kinds) }
        canvasTiles.removeAll()
        canvasWindows.removeAll()
        openCanvasWindowIDs.removeAll()
        save()
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

    // MARK: - Open / close / float

    enum OpenResult {
        case alreadyOpen
        /// The very first panel opened into an empty workspace.
        case dockedDirectly
        /// Opened as a new floating window.
        case floated
    }

    /// Open a panel. Panels always open as their own floating window — the
    /// canvas grid is gone, so there is nothing to dock into. The `zone`
    /// parameter is accepted for call-site compatibility and ignored.
    @discardableResult
    func open(_ kind: WorkspacePanelKind, zone: TilingDropZone? = .right) -> OpenResult {
        guard !isOpen(kind) else { return .alreadyOpen }
        floatingPanels.insert(kind)
        save()
        return .floated
    }

    /// Ensure the navigation "chrome" — the Agents navigator panel with the
    /// Apps launcher beneath it — exists as floating windows. Called at
    /// launch; a saved layout keeps its own set untouched (only missing
    /// panels are added).
    func ensureChromeLayout(navigatorID: UUID) {
        var changed = false
        if floatingPanels.insert(.agents).inserted { changed = true }
        if floatingPanels.insert(.appLauncher).inserted { changed = true }
        if changed { save() }
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


    // MARK: - Default Layout

    /// Reset the open-panel set to the launch chrome (Agents + Apps launcher)
    /// and drop chats whose agent no longer exists, so a reset can never land
    /// on "Agent Not Found". Window positions are reset separately by
    /// `FloatingWindowFrameStore.resetAll()`.
    func resetToDefaultLayout() {
        canvasTiles.removeAll()
        canvasWindows.removeAll()
        openCanvasWindowIDs.removeAll()

        if let workspace = MaestroTools.workspace {
            floatingPanels = floatingPanels.filter { kind in
                if case .agentChat(let id) = kind {
                    return workspace.agent(id: id) != nil
                }
                return true
            }
        } else {
            floatingPanels.removeAll()
        }
        floatingPanels.formUnion([.agents, .appLauncher])
        save()
    }

    /// Restore a layout preset: replace the current open-panel set with the
    /// snapshot stored in the preset. Used by
    /// `WorkspaceLayoutPresetStore.recall()`. Legacy presets captured canvas
    /// tiles, so those kinds are flattened into the floating set — a recall
    /// now opens each of them as its own window (the caller posts
    /// `.workspaceLayoutRecalled` to do that). The Agents chrome is always
    /// kept: it is the app's control centre and sheet host.
    func restorePreset(_ preset: WorkspaceLayoutPreset) {
        canvasTiles.removeAll()
        floatingPanels.removeAll()
        for tile in preset.canvasTiles {
            floatingPanels.formUnion(tile.kinds)
        }
        floatingPanels.formUnion(preset.floatingPanels)
        floatingPanels.insert(.agents)
        isLocked = preset.isLocked
        save()
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

                // Zero-span tiles are corrupt now that the monocle layout is
                // gone; fall through to the clamp (min 4) so they become
                // visible again (or get floated if there's no room).
                let isZeroSpan = canvasTiles[idx].colSpan <= 0 || canvasTiles[idx].rowSpan <= 0

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

    // MARK: - Persistence

    private func save() {
        guard !isDebugNoPersistence else { return }
        let tilesData = try? JSONEncoder().encode(canvasTiles)
        UserDefaults.standard.set(tilesData, forKey: defaultsKey + ".canvasTiles")
        let windowsData = try? JSONEncoder().encode(canvasWindows)
        UserDefaults.standard.set(windowsData, forKey: defaultsKey + ".canvasWindows")
        let floatingData = try? JSONEncoder().encode(Array(floatingPanels))
        UserDefaults.standard.set(floatingData, forKey: defaultsKey + ".floatingPanels")
        UserDefaults.standard.set(isLocked, forKey: defaultsKey + ".isLocked")
        // Note: legacy keys (".root", ".splitRatios", ".layoutAlgorithm") are
        // left in place untouched — backup-before-destructive; nothing reads
        // them anymore.
    }

    private func load() {
        if let tilesData = UserDefaults.standard.data(forKey: defaultsKey + ".canvasTiles"),
           let decoded = try? JSONDecoder().decode([CanvasTile].self, from: tilesData) {
            canvasTiles = decoded
            migrateGridResolutionIfNeeded()
        } else {
            migrateTreeToCanvas()
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
