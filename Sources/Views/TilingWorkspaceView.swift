import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tiling Workspace View

/// The main workspace detail view: renders the recursive binary tree of tiles
/// and wires every leaf tile as a drop target for drag-and-drop tiling.
struct TilingWorkspaceView: View {
    @State private var layout = WorkspaceLayoutState.shared
    @State private var dragState = TilingDragState.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let root = layout.root {
                    TilingNodeView(node: root, path: LayoutPath())
                        .environment(\.tileSize, geometry.size)
                } else {
                    ContentUnavailableView(
                        "Select an Item",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text("Choose an agent or app from the sidebar to open it")
                    )
                }
            }
            .overlay(
                // Empty-workspace drop highlight: when every panel is floating,
                // a panel dragged anywhere over this area docks as the root
                // tile — show the neon outline across the whole workspace.
                emptyWorkspaceDropHighlight
                    .allowsHitTesting(false)
            )
            .onChange(of: geometry.size.width) { _, newValue in
                layout.updateAvailableWidth(newValue)
            }
            .onAppear {
                layout.updateAvailableWidth(geometry.size.width)
            }
        }
        .onChange(of: layout.isLocked) { _, locked in
            // Locking mid-state should never leave a drop highlight behind.
            if locked { dragState.endDrag() }
        }
        .onDrop(
            of: [UTType.workspacePanel.identifier],
            delegate: WorkspaceBackgroundDropDelegate(layout: layout, dragState: dragState)
        )
    }

    @ViewBuilder
    private var emptyWorkspaceDropHighlight: some View {
        if !layout.isLocked, layout.root == nil, dragState.draggedKind != nil {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.cyan, lineWidth: 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.cyan.opacity(0.08))
                )
                .shadow(color: .cyan.opacity(0.9), radius: 8)
                .padding(6)
        }
    }
}

// MARK: - Environment

/// The size of the current tile, passed down through the tree so leaf tiles
/// can compute drop zones from the drop location.
private struct TileSizeKey: EnvironmentKey {
    static let defaultValue: CGSize = CGSize(width: 1_000, height: 1_000)
}

private extension EnvironmentValues {
    var tileSize: CGSize {
        get { self[TileSizeKey.self] }
        set { self[TileSizeKey.self] = newValue }
    }
}

// MARK: - Tiling Node View

/// Recursively renders a `LayoutNode`: splits produce a divider, leaves become
/// a drop target tile, and stacks become a tabbed tile.
struct TilingNodeView: View {
    let node: LayoutNode
    let path: LayoutPath

    var body: some View {
        switch node {
        case .leaf(let kind):
            TilingTileView(kind: kind, stack: [kind])
        case .stack(let kinds):
            TilingStackTileView(kinds: kinds)
        case .split(let axis, _, let first, let second):
            TilingSplitView(axis: axis, path: path, first: first, second: second)
        }
    }
}

// MARK: - Tiling Split View

/// Renders a split node with a draggable divider between two children. The
/// divider adjusts the ratio persisted in `WorkspaceLayoutState`.
struct TilingSplitView: View {
    let axis: LayoutAxis
    let path: LayoutPath
    let first: LayoutNode
    let second: LayoutNode

    @State private var layout = WorkspaceLayoutState.shared

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let ratio = layout.ratio(for: path)
            // Cap firstLength so the divider itself always fits — otherwise at
            // extreme ratios on small tiles the children's frames summed to
            // more than `total` and the second child rendered overlapping the
            // divider/first child.
            let firstLength = min(max(0, total * ratio), max(0, total - dividerThickness))
            let secondLength = max(0, total - firstLength - dividerThickness)

            if axis == .horizontal {
                HStack(spacing: 0) {
                    TilingNodeView(node: first, path: childPath(.first))
                        .frame(width: firstLength)
                    ResizableRatioDivider(axis: axis, path: path, total: total)
                        .frame(width: dividerThickness)
                    TilingNodeView(node: second, path: childPath(.second))
                        .frame(width: secondLength)
                }
            } else {
                VStack(spacing: 0) {
                    TilingNodeView(node: first, path: childPath(.first))
                        .frame(height: firstLength)
                    ResizableRatioDivider(axis: axis, path: path, total: total)
                        .frame(height: dividerThickness)
                    TilingNodeView(node: second, path: childPath(.second))
                        .frame(height: secondLength)
                }
            }
        }
    }

    private var dividerThickness: CGFloat { 9 }

    private func childPath(_ step: LayoutPath.Step) -> LayoutPath {
        var newPath = path
        newPath.steps.append(step)
        return newPath
    }
}

// MARK: - Resizable Ratio Divider

/// A draggable divider that adjusts a split ratio between 0.1 and 0.9.
struct ResizableRatioDivider: View {
    var axis: LayoutAxis
    let path: LayoutPath
    let total: CGFloat

    @State private var layout = WorkspaceLayoutState.shared
    @State private var isHovering = false
    @State private var dragStartRatio: Double?

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(isHovering ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.08))
                .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
        }
        .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
        .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    guard total > 0 else { return }
                    if dragStartRatio == nil {
                        dragStartRatio = layout.ratio(for: path)
                    }
                    let startRatio = dragStartRatio ?? 0.5
                    let delta = axis == .horizontal
                        ? value.location.x - value.startLocation.x
                        : value.location.y - value.startLocation.y
                    let newRatio = (total * startRatio + delta) / total
                    layout.setRatio(newRatio, for: path)
                }
                .onEnded { _ in
                    dragStartRatio = nil
                }
        )
    }
}

// MARK: - Tiling Tile View

/// A single leaf tile: panel header + content, with a drop destination that
/// previews the landing zone as a neon-blue outline.
struct TilingTileView: View {
    let kind: WorkspacePanelKind
    let stack: [WorkspacePanelKind]

    @State private var layout = WorkspaceLayoutState.shared
    @State private var dragState = TilingDragState.shared
    @Environment(ThemeStore.self) private var theme
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(PluginService.self) private var pluginService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.tileSize) private var tileSize

    var body: some View {
        GeometryReader { geometry in
            WorkspacePanelContainer(
                kind: kind,
                title: title(for: kind),
                isDraggable: !layout.isLocked,
                content: { panelContent(for: kind) },
                onFloat: { kind in
                    openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
                }
            )
            // Dim the tile being dragged so it's obvious it's the source and
            // will vacate its spot. Restores the moment the drag ends.
            .opacity(dragState.draggedKind == kind ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.15), value: dragState.draggedKind == kind)
            .onDrop(
                of: [UTType.workspacePanel.identifier],
                delegate: TilingDropDelegate(
                    targetKind: kind,
                    layout: layout,
                    dragState: dragState,
                    tileSize: geometry.size
                )
            )
            .overlay(
                droppableOutline
                    .allowsHitTesting(false)
            )
            .overlay(
                previewOverlay(size: geometry.size)
                    .allowsHitTesting(false)
            )
        }
    }

    /// Faint dashed neon outline shown on every tile that CAN accept the
    /// panel currently being dragged ("droppable here"). The tile actually
    /// under the cursor gets the strong solid zone preview instead.
    @ViewBuilder
    private var droppableOutline: some View {
        if !layout.isLocked,
           let dragged = dragState.draggedKind,
           dragged != kind,
           dragState.targetKind != kind {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(Color.cyan.opacity(0.4))
                .padding(3)
        }
    }

    /// The strong neon-blue zone preview on the tile under the cursor: left /
    /// right / top / bottom halves or the center stack region.
    @ViewBuilder
    private func previewOverlay(size: CGSize) -> some View {
        // Never show the drop highlight while the workspace is locked — a locked
        // workspace can't accept drags, and this also hides any preview left over
        // from a drag that ended without routing through performDrop/dropExited.
        if !layout.isLocked,
           let zone = dragState.targetZone, dragState.targetKind == kind {
            let rect = TilingDropZoneGeometry.previewRect(for: zone, in: size)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.cyan, lineWidth: 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.cyan.opacity(0.10))
                )
                .shadow(color: .cyan.opacity(0.9), radius: 8)
                .frame(width: max(0, rect.width - 5), height: max(0, rect.height - 5))
                .position(x: rect.midX, y: rect.midY)
                .animation(.easeInOut(duration: 0.12), value: dragState.targetZone)
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

    private func panelContent(for kind: WorkspacePanelKind) -> some View {
        WorkspacePanelContentView(kind: kind)
    }
}

// MARK: - Tiling Stack Tile View

/// A tile shared by multiple panels via a top tab bar. Center drops turn into
/// tabs; users can drag a tab out by its grip to split it into its own tile.
struct TilingStackTileView: View {
    let kinds: [WorkspacePanelKind]
    @State private var selectedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    StackTabButton(
                        kind: kind,
                        isSelected: selectedIndex == index,
                        action: { selectedIndex = index }
                    )
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.15))

            if kinds.indices.contains(selectedIndex) {
                TilingTileView(kind: kinds[selectedIndex], stack: kinds)
            }
        }
    }
}

private struct StackTabButton: View {
    let kind: WorkspacePanelKind
    let isSelected: Bool
    let action: () -> Void
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(PluginService.self) private var pluginService
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: kind.icon)
                    .font(.caption2)
                    .foregroundStyle(theme.panelAccent(for: kind))
                Text(shortTitle)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? theme.panelAccent(for: kind).opacity(0.2) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var title: String {
        switch kind {
        case .agentChat(let id):
            return workspace.agent(id: id)?.name ?? "Agent"
        case .plugin(let id):
            return pluginService.manifest(id: id)?.name ?? "Plugin"
        default:
            return kind.staticDisplayName ?? "Panel"
        }
    }

    private var shortTitle: String {
        if title.count > 14 { return String(title.prefix(12)) + "…" }
        return title
    }
}
