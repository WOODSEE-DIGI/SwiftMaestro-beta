import SwiftUI

// MARK: - Workspace Panel Container
//
// Wraps a top-level workspace panel (an agent's chat, Notes.md, Apple Notes,
// Calendar, Reminders, Contacts, Canvas, or Kanban) with a lightweight header:
// icon + title, an obvious drag grip for tiling drag-and-drop, and a close
// button. The multi-panel analogue of `PanelContainer`, which serves the same
// role one level down for Plans/Tasks/Terminal inside a single agent's chat.
struct WorkspacePanelContainer<Content: View>: View {

    let kind: WorkspacePanelKind
    let title: String
    /// Whether the panel can be dragged to another tile. Disabled when the
    /// workspace is locked.
    var isDraggable: Bool = true
    @ViewBuilder let content: () -> Content
    /// Called when the user chooses "Pop Out to Window" — the caller is
    /// responsible for actually presenting the floating window via
    /// `openWindow(id:value:)`.
    var onFloat: ((WorkspacePanelKind) -> Void)? = nil

    /// Canvas mode: when non-nil, dragging the header live-moves the tile
    /// (no AppKit drag session). Floating-window hosts leave these nil and
    /// keep the AppKit drag grip so panels can be dropped back onto a canvas.
    var onHeaderDragChanged: ((DragGesture.Value) -> Void)? = nil
    var onHeaderDragEnded: ((DragGesture.Value) -> Void)? = nil

    /// The canvas tile hosting this panel (nil when floating in a window).
    /// Enables the "Move to ▸" canvas-window menu.
    var canvasTileID: UUID? = nil

    @State private var layout = WorkspaceLayoutState.shared
    @Environment(PanelLayoutState.self) private var panelLayout
    @Environment(ThemeStore.self) private var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
                // The header must always win the layout negotiation: when a
                // panel's content has a large minimum height (e.g. MaestroDocs'
                // welcome state) and the tile is short, the overflowing VStack
                // used to get clipped at BOTH edges — cutting the header off
                // the top entirely. fixedSize pins the header to its ideal
                // height; the content below absorbs the crunch instead.
                .fixedSize(horizontal: false, vertical: true)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // A content view whose minimum height exceeds its slot (e.g.
                // MaestroDocs' welcome state in a short tile) overflows the
                // slot CENTERED — painting over the header above it and making
                // the panel impossible to move or close. Clip at the slot
                // boundary: the header always survives, content loses its
                // bottom edge instead.
                .clipped()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        let row = HStack(spacing: 6) {
            // Drag affordance: canvas tiles live-move via a header gesture;
            // floating windows keep the AppKit grip (drag-and-drop).
            if onHeaderDragChanged != nil {
                Image(systemName: layout.isLocked ? "lock" : "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .help(layout.isLocked ? "Workspace is locked" : "Drag to move")
            } else if isDraggable {
                PanelDragGrip(kind: kind, title: title, accent: theme.panelAccent(for: kind))
                    .frame(width: 22, height: 20)
            } else {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .help("Workspace is locked")
            }

            Image(systemName: kind.icon)
                .font(.caption)
                .foregroundStyle(theme.panelAccent(for: kind))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Plans quick-toggle: left side near agent name for easy access
            if case .agentChat = kind {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        panelLayout.toggleVisibility(.plans)
                    }
                } label: {
                    Image(systemName: panelLayout.hiddenPanels.contains(.plans)
                        ? "list.bullet.rectangle" : "list.bullet.rectangle.fill")
                        .font(.caption)
                        .foregroundStyle(panelLayout.hiddenPanels.contains(.plans)
                            ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(panelLayout.hiddenPanels.contains(.plans)
                    ? "Show Plans panel" : "Hide Plans panel")
            }

            Spacer()

            if case .agentChat(let id) = kind {
                ChatPanelHeaderToolbar(agentID: id)
            }

            Menu {
                contextMenuContent
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    layout.close(kind)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close panel")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.panelAccent(for: kind).opacity(0.2))

        // Canvas tiles: the whole header is the move handle (the grip icon is
        // just the affordance). minimumDistance 3 keeps buttons clickable.
        if let onHeaderDragChanged {
            row
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named(WorkspaceCanvasCoordinateSpace.name))
                        .onChanged(onHeaderDragChanged)
                        .onEnded { value in onHeaderDragEnded?(value) }
                )
        } else {
            row
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if let onFloat {
            Button {
                layout.float(kind)
                onFloat(kind)
            } label: {
                Label("Pop Out to Window", systemImage: "rectangle.expand.vertical")
            }
        }

        // Move this tile between canvas windows (main + secondary canvases,
        // e.g. a group of panels living on a second monitor as one window).
        if let tileID = canvasTileID, let tile = layout.canvasTile(id: tileID) {
            Menu {
                if tile.canvasID != CanvasTile.mainCanvasID {
                    Button("Main Window") {
                        layout.moveTileToCanvas(tileID, canvasID: CanvasTile.mainCanvasID)
                    }
                }
                ForEach(layout.canvasWindows) { window in
                    if window.id != tile.canvasID {
                        Button(window.name) {
                            layout.moveTileToCanvas(tileID, canvasID: window.id)
                        }
                    }
                }
                Divider()
                Button("New Canvas Window…") {
                    let info = layout.createCanvasWindow()
                    layout.moveTileToCanvas(tileID, canvasID: info.id)
                    openWindow(id: "canvas-window", value: info.id)
                }
            } label: {
                Label("Move to", systemImage: "rectangle.portrait.arrowtriangle.2.outward")
            }
        }
    }
}
