import SwiftUI
import UniformTypeIdentifiers

// MARK: - Canvas Coordinate Space

/// Named coordinate space of the workspace canvas, so drag gestures on tile
/// headers/tabs can report pointer positions in canvas points.
enum WorkspaceCanvasCoordinateSpace {
    static let name = "workspaceCanvas"
}

// MARK: - Canvas Drag State

/// Tracks an in-progress tile move/resize so the canvas can paint the target
/// cell ghost and other tiles can highlight. (DnD of floating panels uses
/// `TilingDragState` instead.)
@Observable
@MainActor
final class CanvasDragState {
    static let shared = CanvasDragState()
    /// Tile currently being live-moved.
    var movingTileID: UUID?
    /// Tile currently being resized.
    var resizingTileID: UUID?
    /// Live pixel translation during a move (the store only learns the final
    /// cell on drop — the tile renders frame + this offset mid-drag).
    var dragTranslation: CGSize = .zero
    /// Live pixel delta during a resize (width/height grow by this).
    var resizeDelta: CGSize = .zero
    /// Current pointer position in canvas coordinates (during a tile move).
    var pointer: CGPoint = .zero
    /// Whether Shift is held during a tile move — stacking as tabs is ONLY
    /// allowed with Shift down; a plain drop onto another tile swaps instead.
    var stackModifierHeld = false
    /// A drag-and-drop session (from a floating window) is over this canvas.
    var externalDragActive = false
}

// MARK: - Canvas Workspace View

/// The workspace detail view: a 12×8 grid canvas. Tiles occupy whole cell
/// spans — DOCKED TILES NEVER OVERLAP (only floating windows may overlap).
/// Empty cells are the visible free space. Dragging a tile's header moves it
/// (live pixel-follow, snaps into cells on drop); dropping onto an occupied
/// span swaps positions; dragging near a canvas edge snaps to that half when
/// the area is free. **Shift + drop** on a tile's center stacks them as tabs —
/// stacking is a deliberate Shift gesture, never the default. The
/// bottom-right corner resizes by cell span, clamped at neighbours.
///
/// One instance per window (`canvasID`) — the main window plus any secondary
/// canvas windows, so a group of panels can live as one window on a second
/// display.
struct CanvasWorkspaceView: View {
    let canvasID: UUID

    @State private var layout = WorkspaceLayoutState.shared
    @State private var dragState = TilingDragState.shared
    @State private var canvasDrag = CanvasDragState.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                gridBackground(in: geometry.size)

                if layout.tiles(for: canvasID).isEmpty {
                    ContentUnavailableView(
                        "Select an Item",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Choose an agent or app from the sidebar to open it")
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                ForEach(layout.tiles(for: canvasID)) { tile in
                    CanvasTileView(tileID: tile.id, canvasSize: geometry.size)
                }

                // Ghost of the cell span a moved tile will land in.
                if let ghost = moveGhostRect(in: geometry.size) {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .foregroundStyle(Color.cyan.opacity(0.7))
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.cyan.opacity(0.06))
                        )
                        .frame(width: ghost.width, height: ghost.height)
                        .position(x: ghost.midX, y: ghost.minY + ghost.height / 2)
                        .allowsHitTesting(false)
                        .animation(.linear(duration: 0.06), value: ghost)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: WorkspaceCanvasCoordinateSpace.name)
            .contentShape(Rectangle())
            .overlay {
                // Neon glow while a floating-panel drag is over this canvas —
                // "drop here to dock" affordance.
                if canvasDrag.externalDragActive, !layout.isLocked {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.cyan, lineWidth: 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.cyan.opacity(0.08))
                        )
                        .shadow(color: .cyan.opacity(0.9), radius: 8)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { layout.clampTilesToCanvas(geometry.size, canvasID: canvasID) }
            .onChange(of: geometry.size) { _, newSize in
                layout.clampTilesToCanvas(newSize, canvasID: canvasID)
            }
            .onDrop(
                of: [UTType.workspacePanel.identifier],
                delegate: CanvasBackgroundDropDelegate(layout: layout, dragState: dragState, canvasID: canvasID)
            )
        }
        .onChange(of: layout.isLocked) { _, locked in
            if locked { dragState.endDrag() }
        }
        // Track open/closed so the Window menu can reopen a closed canvas
        // (its tiles stay assigned to it and reappear on reopen).
        .onAppear { layout.markCanvasWindowOpen(canvasID) }
        .onDisappear { layout.markCanvasWindowClosed(canvasID) }
        // Menu > Window → Close Canvas Window removes the canvas from state;
        // this view notices and closes its own window (the observer below
        // then no-ops — removal is idempotent).
        .onChange(of: layout.canvasWindows.map(\.id)) { _, ids in
            if canvasID != CanvasTile.mainCanvasID && !ids.contains(canvasID) {
                dismiss()
            }
        }
        #if os(macOS)
        .background(
            WindowCloseObserver {
                // Closing a secondary canvas window REMOVES it — tiles migrate
                // back to the main canvas. Without this, the closed canvas
                // stayed in the persisted layout forever and reopened on every
                // launch with no way to get rid of it.
                // (App quit does not send willClose, so open canvases still
                // restore correctly across restarts.)
                if canvasID != CanvasTile.mainCanvasID {
                    layout.removeCanvasWindow(id: canvasID)
                }
            }
        )
        #endif
    }

    // MARK: - Grid background + move ghost

    /// Faint dots at cell corners — the grid is subtly visible so the snapping
    /// model is discoverable instead of invisible.
    private func gridBackground(in size: CGSize) -> some View {
        Canvas { context, _ in
            let cell = CanvasGrid.cellSize(in: size)
            let dotColor = colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.08)
            var x = CanvasGrid.gap
            while x < size.width {
                var y = CanvasGrid.gap
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                        with: .color(dotColor)
                    )
                    y += cell.height + CanvasGrid.gap
                }
                x += cell.width + CanvasGrid.gap
            }
        }
        .allowsHitTesting(false)
    }

    /// Where the actively-dragged tile would land: its pixel frame plus the
    /// live drag translation, quantized to the containing cells.
    private func moveGhostRect(in size: CGSize) -> CGRect? {
        guard let movingID = canvasDrag.movingTileID,
              let tile = layout.canvasTile(id: movingID) else { return nil }
        let frame = tile.frame(in: size)
        let moved = frame.offsetBy(dx: canvasDrag.dragTranslation.width,
                                   dy: canvasDrag.dragTranslation.height)
        let originCell = CanvasGrid.cell(at: moved.origin, in: size)
        let col = min(originCell.col, CanvasGrid.cols - tile.colSpan)
        let row = min(originCell.row, CanvasGrid.rows - tile.rowSpan)
        return CanvasGrid.frame(col: col, row: row, colSpan: tile.colSpan, rowSpan: tile.rowSpan, in: size)
    }

    /// The half-canvas rect for an edge snap preview.
    func edgeHalfRect(_ edge: TilingDropZone, in size: CGSize) -> CGRect {
        switch edge {
        case .left: return CanvasGrid.frame(col: 0, row: 0, colSpan: CanvasGrid.cols / 2, rowSpan: CanvasGrid.rows, in: size)
        case .right: return CanvasGrid.frame(col: CanvasGrid.cols / 2, row: 0, colSpan: CanvasGrid.cols / 2, rowSpan: CanvasGrid.rows, in: size)
        case .top: return CanvasGrid.frame(col: 0, row: 0, colSpan: CanvasGrid.cols, rowSpan: CanvasGrid.rows / 2, in: size)
        case .bottom: return CanvasGrid.frame(col: 0, row: CanvasGrid.rows / 2, colSpan: CanvasGrid.cols, rowSpan: CanvasGrid.rows / 2, in: size)
        case .center: return CanvasGrid.frame(col: 0, row: 0, colSpan: CanvasGrid.cols, rowSpan: CanvasGrid.rows, in: size)
        }
    }
}

// MARK: - Canvas Background Drop Delegate

/// Drop delegate for the canvas background: a floating panel dropped anywhere
/// docks into the containing cell. (Canvas tiles live-move via header drag
/// instead of drag-and-drop, so this only sees drags from floating windows.)
@MainActor
struct CanvasBackgroundDropDelegate: DropDelegate {
    let layout: WorkspaceLayoutState
    let dragState: TilingDragState
    let canvasID: UUID

    func validateDrop(info: DropInfo) -> Bool {
        !layout.isLocked && info.hasItemsConforming(to: [UTType.workspacePanel])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        CanvasDragState.shared.externalDragActive = true
    }

    func dropExited(info: DropInfo) {
        CanvasDragState.shared.externalDragActive = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let source = dragState.draggedKind
        dragState.endDrag()
        CanvasDragState.shared.externalDragActive = false
        guard validateDrop(info: info), let source else { return false }
        layout.dockAt(source, origin: info.location, canvasID: canvasID)
        return true
    }
}

// MARK: - Canvas Tile View

/// One tile on the grid canvas: optional tab strip (stacked panels) + the
/// panel container, at the tile's cell-span frame. Header drag live-moves
/// (pixel-follow) and commits to cells on drop; the corner grip resizes by
/// span. Overlap is impossible — a drop onto an occupied span swaps cells.
struct CanvasTileView: View {
    let tileID: UUID
    let canvasSize: CGSize

    @State private var layout = WorkspaceLayoutState.shared
    @State private var canvasDrag = CanvasDragState.shared
    @Environment(ThemeStore.self) private var theme
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(PluginService.self) private var pluginService
    @Environment(\.openWindow) private var openWindow

    @State private var selectedTabIndex = 0

    var body: some View {
        if let tile = layout.canvasTile(id: tileID) {
            let kind = tile.kinds[min(selectedTabIndex, tile.kinds.count - 1)]
            let baseFrame = tile.frame(in: canvasSize)

            // Live pixel-follow while this tile is dragged/resized.
            let isMoving = canvasDrag.movingTileID == tile.id
            let isResizing = canvasDrag.resizingTileID == tile.id
            let frame = baseFrame
                .offsetBy(dx: isMoving ? canvasDrag.dragTranslation.width : 0,
                          dy: isMoving ? canvasDrag.dragTranslation.height : 0)
                .resized(by: isResizing ? canvasDrag.resizeDelta : .zero)

            VStack(spacing: 0) {
                if tile.kinds.count > 1 {
                    tabStrip(tile: tile)
                }
                WorkspacePanelContainer(
                    kind: kind,
                    title: title(for: kind),
                    isDraggable: !layout.isLocked,
                    content: { WorkspacePanelContentView(kind: kind) },
                    onFloat: { kind in
                        openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
                    },
                    onHeaderDragChanged: layout.isLocked ? nil : { value in headerDragChanged(value, tile: tile) },
                    onHeaderDragEnded: layout.isLocked ? nil : { value in headerDragEnded(value, tile: tile) },
                    canvasTileID: tile.id
                )
            }
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor(for: tile), lineWidth: 1.5)
            )
            // Dashed "droppable here" outline on every OTHER tile mid-move.
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .foregroundStyle(Color.cyan.opacity(0.4))
                    .padding(3)
                    .opacity(canvasDrag.movingTileID != nil && canvasDrag.movingTileID != tile.id ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(isMoving ? 0.55 : 0.35), radius: isMoving ? 14 : 10, y: 4)
            // Overlays MUST come before .position — overlays after .position
            // are laid out in the parent coordinate space, detaching them from
            // the tile frame (the resize grip would float at the wrong spot).
            .overlay(alignment: .bottomTrailing) { resizeHandle(tile: tile) }
            .overlay { stackPreviewOverlay(tile: tile) }
            // NB: .position, never .offset — an .offset child in an aligned
            // ZStack is CENTERED first and offset second (SwiftUI behavior),
            // which displaced every tile and detached overlays from the
            // rendered frame. .position places the center at exact canvas
            // coordinates and overlays follow it correctly.
            .position(x: frame.midX, y: frame.midY)
            .zIndex(isMoving ? 10_000 : Double(tile.z))
            .simultaneousGesture(
                TapGesture().onEnded { layout.bringTileToFront(tileID) }
            )
        }
    }

    private func title(for kind: WorkspacePanelKind) -> String {
        if case .agentChat(let id) = kind {
            return workspace.agent(id: id)?.name ?? "Agent"
        }
        if case .plugin(let id) = kind {
            return pluginService.manifest(id: id)?.name ?? "Plugin"
        }
        return kind.staticDisplayName ?? "Panel"
    }

    /// Border brightens while another tile's Shift-drag hovers this tile's
    /// center (the stack-as-tabs affordance only exists with Shift down).
    private func borderColor(for tile: CanvasTile) -> Color {
        if canvasDrag.stackModifierHeld, canvasDrag.movingTileID != nil, canvasDrag.movingTileID != tile.id {
            let center = tile.frame(in: canvasSize)
                .insetBy(dx: tile.frame(in: canvasSize).width * 0.25,
                         dy: tile.frame(in: canvasSize).height * 0.25)
            if center.contains(canvasDrag.pointer) { return .cyan }
        }
        return theme.isDarkAppearanceActive ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    }
}

private extension CGRect {
    /// Grow/shrink the size keeping the origin (used for live resize render).
    func resized(by delta: CGSize) -> CGRect {
        CGRect(x: minX, y: minY,
               width: max(80, width + delta.width),
               height: max(60, height + delta.height))
    }
}

// MARK: - Tile Move / Resize / Snap

extension CanvasTileView {

    /// Live pixel-follow while dragging the header; the store only learns the
    /// final cell on drop (the ghost preview reads the shared translation).
    func headerDragChanged(_ value: DragGesture.Value, tile: CanvasTile) {
        if canvasDrag.movingTileID != tile.id {
            canvasDrag.movingTileID = tile.id
            canvasDrag.dragTranslation = .zero
            layout.bringTileToFront(tile.id)
        }
        canvasDrag.dragTranslation = value.translation
        canvasDrag.pointer = value.location
        canvasDrag.stackModifierHeld = NSEvent.modifierFlags.contains(.shift)
    }

    /// The cell span an edge snap would occupy (for occupancy checks).
    static func snapSpan(for edge: TilingDropZone) -> (col: Int, row: Int, colSpan: Int, rowSpan: Int) {
        switch edge {
        case .left: return (0, 0, CanvasGrid.cols / 2, CanvasGrid.rows)
        case .right: return (CanvasGrid.cols / 2, 0, CanvasGrid.cols / 2, CanvasGrid.rows)
        case .top: return (0, 0, CanvasGrid.cols, CanvasGrid.rows / 2)
        case .bottom: return (0, CanvasGrid.rows / 2, CanvasGrid.cols, CanvasGrid.rows / 2)
        case .center: return (0, 0, CanvasGrid.cols, CanvasGrid.rows)
        }
    }

    /// Drop resolution on the grid:
    /// - pointer near a canvas EDGE → snap to that half of the grid, but only
    ///   when the area is empty (or holds one tile, which we swap with) —
    ///   snapping over several tiles would bury them (no-overlap rule)
    /// - SHIFT + pointer over another tile's CENTER → stack as tabs
    /// - plain pointer over another tile's center → swap cells
    /// - target span occupied by ONE other tile → swap cells
    /// - otherwise → move into the quantized cells (no overlaps possible)
    func headerDragEnded(_ value: DragGesture.Value, tile: CanvasTile) {
        let translation = canvasDrag.dragTranslation
        let shiftHeld = canvasDrag.stackModifierHeld || NSEvent.modifierFlags.contains(.shift)
        canvasDrag.movingTileID = nil
        canvasDrag.dragTranslation = .zero
        canvasDrag.stackModifierHeld = false

        let localTiles = layout.tiles(for: tile.canvasID).filter { $0.id != tile.id }
        let pointer = value.location

        if let edge = Self.canvasEdge(for: pointer, canvasSize: canvasSize) {
            let snapSpan = Self.snapSpan(for: edge)
            let blockers = localTiles.filter { CanvasGrid.spansIntersect($0.cellSpan, snapSpan) }
            if blockers.isEmpty {
                layout.snapTileToCanvasEdge(tile.id, edge: edge)
                return
            }
            if blockers.count == 1, let other = blockers.first {
                layout.swapTiles(tile.id, other.id)
                return
            }
            // Several tiles in the snap area: fall through to normal resolution.
        }

        let baseFrame = tile.frame(in: canvasSize)
        let movedOrigin = CGPoint(x: baseFrame.minX + translation.width,
                                  y: baseFrame.minY + translation.height)
        let targetCell = CanvasGrid.cell(at: movedOrigin, in: canvasSize)
        let col = min(targetCell.col, CanvasGrid.cols - tile.colSpan)
        let row = min(targetCell.row, CanvasGrid.rows - tile.rowSpan)
        let candidate = (col: col, row: row, colSpan: tile.colSpan, rowSpan: tile.rowSpan)
        let overlapped = localTiles.filter { CanvasGrid.spansIntersect($0.cellSpan, candidate) }

        // Shift + center drop → stack as tabs (any tile whose center is under
        // the pointer, whether or not the span overlaps it).
        if shiftHeld, let stackTarget = localTiles.first(where: {
            let f = $0.frame(in: canvasSize)
            return f.insetBy(dx: f.width * 0.25, dy: f.height * 0.25).contains(pointer)
        }) {
            layout.stackTile(tile.id, onto: stackTarget.id)
            return
        }

        if overlapped.isEmpty {
            layout.moveTile(tile.id, toCol: col, row: row)
        } else if overlapped.count == 1, let other = overlapped.first {
            layout.swapTiles(tile.id, other.id)
        }
        // Multi-overlap (dropping across a cell junction): stay put.
    }

    /// Near-edge detection for half-canvas snapping (24pt bands).
    static func canvasEdge(for point: CGPoint, canvasSize: CGSize) -> TilingDropZone? {
        let band = 24.0
        if point.x <= band { return .left }
        if point.x >= canvasSize.width - band { return .right }
        if point.y <= band { return .top }
        if point.y >= canvasSize.height - band { return .bottom }
        return nil
    }
}

extension CanvasTileView {

    /// Stack-as-tabs preview on a tile while another tile's Shift-drag hovers
    /// its center zone. (No Shift → no stacking, so no preview.)
    @ViewBuilder
    func stackPreviewOverlay(tile: CanvasTile) -> some View {
        if canvasDrag.stackModifierHeld, canvasDrag.movingTileID != nil, canvasDrag.movingTileID != tile.id {
            let f = tile.frame(in: canvasSize)
            let center = f.insetBy(dx: f.width * 0.25, dy: f.height * 0.25)
            if center.contains(canvasDrag.pointer) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.cyan, lineWidth: 2.5)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.cyan.opacity(0.10))
                    )
                    .shadow(color: .cyan.opacity(0.9), radius: 8)
                    .frame(width: f.width - 10, height: f.height - 10)
                    .position(x: f.width / 2, y: f.height / 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Bottom-right resize grip — a visible diagonal-lines handle, live pixel
    /// follow, span commit on release.
    @ViewBuilder
    func resizeHandle(tile: CanvasTile) -> some View {
        if !layout.isLocked {
            Canvas { context, size in
                // Three diagonal lines, classic window-corner affordance.
                for i in 0..<3 {
                    let inset = CGFloat(i) * 6 + 4
                    var path = Path()
                    path.move(to: CGPoint(x: size.width - inset, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: size.height - inset))
                    context.stroke(path, with: .color(theme.isDarkAppearanceActive ? .white.opacity(0.45) : .black.opacity(0.35)), lineWidth: 1.5)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(WorkspaceCanvasCoordinateSpace.name))
                    .onChanged { value in
                        if canvasDrag.resizingTileID != tile.id {
                            canvasDrag.resizingTileID = tile.id
                            canvasDrag.resizeDelta = .zero
                            layout.bringTileToFront(tile.id)
                        }
                        canvasDrag.resizeDelta = value.translation
                    }
                    .onEnded { _ in
                        let delta = canvasDrag.resizeDelta
                        canvasDrag.resizingTileID = nil
                        canvasDrag.resizeDelta = .zero
                        let cell = CanvasGrid.cellSize(in: canvasSize)
                        let base = tile.frame(in: canvasSize)
                        let newColSpan = max(tile.minColSpan, min(
                            CanvasGrid.cols - tile.col,
                            Int(((base.width + delta.width) / (cell.width + CanvasGrid.gap)).rounded())
                        ))
                        let newRowSpan = max(tile.minRowSpan, min(
                            CanvasGrid.rows - tile.row,
                            Int(((base.height + delta.height) / (cell.height + CanvasGrid.gap)).rounded())
                        ))
                        layout.resizeTileSpan(tile.id, colSpan: newColSpan, rowSpan: newRowSpan)
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize")
        }
    }
}

// MARK: - Canvas Tab Strip

extension CanvasTileView {
    /// Tab strip shown when a tile stacks multiple panels. Click selects;
    /// dragging a tab out (>24pt) splits it into its own tile.
    @ViewBuilder
    func tabStrip(tile: CanvasTile) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(tile.kinds.enumerated()), id: \.element) { index, kind in
                let isSelected = min(selectedTabIndex, tile.kinds.count - 1) == index
                HStack(spacing: 4) {
                    Image(systemName: kind.icon)
                        .font(.caption2)
                        .foregroundStyle(theme.panelAccent(for: kind))
                    Text(shortTitle(for: kind))
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? theme.panelAccent(for: kind).opacity(0.2) : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture { selectedTabIndex = index }
                .gesture(
                    DragGesture(minimumDistance: 24, coordinateSpace: .named(WorkspaceCanvasCoordinateSpace.name))
                        .onEnded { _ in
                            guard !layout.isLocked else { return }
                            if selectedTabIndex > 0, tile.kinds.count > 1 {
                                selectedTabIndex -= 1
                            }
                            layout.detachKind(kind, from: tile.id)
                        }
                )
                .help(title(for: kind))
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.15))
    }

    private func shortTitle(for kind: WorkspacePanelKind) -> String {
        let t = title(for: kind)
        return t.count > 14 ? String(t.prefix(12)) + "…" : t
    }
}
