import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Identifies a floating window for a top-level workspace panel.
struct WorkspacePanelWindowID: Hashable, Codable {
    let kind: WorkspacePanelKind
}

/// Floating window content for any workspace panel (agent chat, Notes.md,
/// Apple Notes, Calendar, Reminders, Contacts, Canvas, Kanban). New panels
/// open this way by default — the user drags the window wherever they like
/// (including to a second monitor) and can dock it back into the main
/// window's grid via the header's Dock button, or leave it floating
/// indefinitely. Reuses `WorkspacePanelContentView` so the content is
/// identical to the docked version.
struct WorkspacePanelWindowView: View {
    let target: WorkspacePanelWindowID

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(PluginService.self) private var pluginService
    @Environment(ThemeStore.self) private var theme
    @Environment(WebBrowserStore.self) private var webBrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var layout = WorkspaceLayoutState.shared
    /// Set right before we dismiss the window ourselves (via "Dock"), so the
    /// close-detection below doesn't also mark the panel fully closed —
    /// `dock(_:)` already moved it into the grid; closing on top of that
    /// would incorrectly remove it again.
    @State private var didDock = false
    /// Keep this window in front of all others. Opt-in, off by default.
    @State private var isPinnedToFront = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WorkspacePanelContentView(kind: target.kind)
        }
        .background(theme.background)
        .frame(minWidth: 420, minHeight: 360)
        // Overrides the WindowGroup's static "Panel" title with the actual
        // panel name (e.g. "Contacts", "Calendar") — same pattern as
        // `PlanWindowView.navigationTitle(plan.title)`.
        .navigationTitle(title)
        .onChange(of: layout.isFloating(target.kind)) { _, isFloating in
            // The panel left the floating set without going through this
            // window's own Dock menu — i.e. it was drag-dropped into the
            // main window's tiling grid. This window's job is done. Setting
            // didDock first keeps the close observer from marking the panel
            // closed — it lives on, docked, in the grid.
            if !isFloating {
                didDock = true
                dismiss()
            }
        }
        #if os(macOS)
        .background(
            // Agent-chat panels need the same comfortable default size as the
            // dedicated `AgentChatWindow`; otherwise an empty chat can collapse
            // the workspace panel window to an unusable size.
            Group {
                if case .agentChat = target.kind {
                    WindowSizeConfigurator(
                        minSize: CGSize(width: 720, height: 520),
                        defaultSize: CGSize(width: 960, height: 720),
                        backgroundColor: nil
                    )
                } else {
                    EmptyView()
                }
            }
        )
        .background(
            WindowCloseObserver {
                // The user closed this window some other way than the Dock
                // button (red close button, Cmd+W, ⌘Q, etc.) — the panel is
                // now genuinely closed, not just moved, so clear it from
                // `floatingPanels` too. Otherwise it'd stay marked "open"
                // forever (stale sidebar indicator, and `open(_:)` would
                // silently no-op on any future attempt to reopen it).
                if !didDock {
                    layout.close(target.kind)
                }
            }
        )
        .background(WindowPinConfigurator(isPinned: isPinnedToFront))
        .background(WindowCascadeConfigurator())
        .background(
            WindowFocusObserver(
                name: .bringWorkspacePanelToFront,
                match: { [kind = target.kind] object in
                    guard let objectKind = object as? WorkspacePanelKind else { return false }
                    return objectKind == kind
                }
            )
        )
        #endif
    }

    private var title: String {
        if case .agentChat(let id) = target.kind {
            return workspace.agent(id: id)?.name ?? "Agent"
        }
        if case .plugin(let id) = target.kind {
            return pluginService.manifest(id: id)?.name ?? "Plugin"
        }
        if case .terminal(let id) = target.kind {
            let terminals = layout.allOpenPanels.filter {
                if case .terminal = $0 { return true }
                return false
            }
            if let index = terminals.firstIndex(where: {
                if case .terminal(let tid) = $0 { return tid == id }
                return false
            }) {
                return "Terminal \(index + 1)"
            }
            return "Terminal"
        }
        return target.kind.staticDisplayName ?? "Panel"
    }

    /// Dock this floating panel into the main window in the given direction
    /// (side-by-side for left/right, stacked for bottom), then close this window.
    private func dockPanel(_ zone: TilingDropZone) {
        didDock = true
        layout.dock(target.kind, zone: zone)
        dismiss()
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Drag grip: drag this window into the main window's tiling grid.
            // While dragging, every tile in the main window shows its neon
            // drop-zone preview; releasing docks the panel in that position
            // and this window closes itself (see the isFloating observer).
            if layout.isLocked {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 20)
                    .help("Workspace is locked")
            } else {
                PanelDragGrip(
                    kind: target.kind,
                    title: title,
                    accent: theme.panelAccent(for: target.kind),
                    toolTip: "Drag into the main window to dock this panel"
                )
                .frame(width: 22, height: 20)
            }

            Image(systemName: target.kind.icon)
                .font(.caption)
                .foregroundStyle(theme.panelAccent(for: target.kind))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if case .agentChat(let id) = target.kind {
                ChatPanelHeaderToolbar(agentID: id)
            }

            Button {
                isPinnedToFront.toggle()
            } label: {
                Label(
                    isPinnedToFront ? "Unpin" : "Keep on Top",
                    systemImage: isPinnedToFront ? "pin.fill" : "pin"
                )
                .font(.caption2)
            }
            .buttonStyle(.plain)
            .help(isPinnedToFront
                ? "Stop keeping this window in front of all others"
                : "Keep this window in front of all others")

            Menu {
                Button {
                    dockPanel(.right)
                } label: {
                    Label("Dock to Right", systemImage: "rectangle.split.2x1")
                }
                Button {
                    dockPanel(.left)
                } label: {
                    Label("Dock to Left", systemImage: "rectangle.split.2x1")
                }
                Divider()
                Button {
                    dockPanel(.bottom)
                } label: {
                    Label("Dock Below", systemImage: "rectangle.split.1x2")
                }
            } label: {
                Label("Dock", systemImage: "rectangle.on.rectangle")
                    .font(.caption2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Dock into the main window — choose a side or below")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.panelAccent(for: target.kind).opacity(0.2))
    }
}


