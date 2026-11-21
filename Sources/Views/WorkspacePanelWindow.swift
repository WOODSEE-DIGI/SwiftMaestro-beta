import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Identifies a floating window for a top-level workspace panel.
struct WorkspacePanelWindowID: Hashable, Codable {
    let kind: WorkspacePanelKind
}

extension WorkspacePanelKind {
    /// Minimum content size for this panel's floating window. Also the floor
    /// `FloatingWindowFrameStore` clamps a restored frame up to, so a frame
    /// saved under an older (smaller) minimum can never reopen unusable.
    var floatingMinSize: CGSize {
        switch self {
        case .agentChat: return CGSize(width: 720, height: 520)
        case .damBrowser: return CGSize(width: 900, height: 620)
        case .agents: return CGSize(width: 240, height: 420)
        case .appLauncher: return CGSize(width: 220, height: 160)
        default: return CGSize(width: 420, height: 360)
        }
    }

    /// Default content size used when a window has no saved frame and would
    /// otherwise be smaller than the panel's minimum.
    var floatingDefaultSize: CGSize {
        switch self {
        case .agentChat: return CGSize(width: 960, height: 720)
        case .damBrowser: return CGSize(width: 1280, height: 820)
        case .agents: return CGSize(width: 300, height: 720)
        case .appLauncher: return CGSize(width: 1100, height: 520)
        default: return CGSize(width: 720, height: 560)
        }
    }
}

/// Floating window content for any workspace panel (agent chat, Notes.md,
/// Apple Notes, Calendar, Reminders, Contacts, Kanban). Every panel opens
/// this way — the user drags the window wherever they like, including to a
/// second monitor, and closes it with the header's ✕. Reuses
/// `WorkspacePanelContentView` so the content is identical everywhere.
struct WorkspacePanelWindowView: View {
    let target: WorkspacePanelWindowID

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(PluginService.self) private var pluginService
    @Environment(ThemeStore.self) private var theme
    @Environment(WebBrowserStore.self) private var webBrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var layout = WorkspaceLayoutState.shared
    /// Per-window Plans/Tasks layout state shared with the header toolbar and
    /// the embedded agent chat.
    @State private var panelLayout = PanelLayoutState()
    /// Keep this window in front of all others. Opt-in, off by default.
    @State private var isPinnedToFront = false
    /// Tracks the Apps launcher view mode so the frame configurator can store
    /// and restore a separate position for List, Grid, and Icons.
    @AppStorage("appsLauncher.viewMode") private var appsViewMode: AppsLauncherPanel.ViewMode = .grid

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            WorkspacePanelContentView(kind: target.kind)
        }
        .environment(panelLayout)
        .background(theme.background)
        .frame(minWidth: target.kind.floatingMinSize.width,
               minHeight: target.kind.floatingMinSize.height)
        // Overrides the WindowGroup's static "Panel" title with the actual
        // panel name (e.g. "Contacts", "Calendar") — same pattern as
        // `PlanWindowView.navigationTitle(plan.title)`.
        .navigationTitle(title)
        .onChange(of: layout.isFloating(target.kind)) { _, isFloating in
            // The panel left the open set without this window being closed
            // first (a workspace-layout recall, a `close_panel` tool call).
            // Nothing left to show — dismiss; the close observer below sees
            // the panel is already closed and leaves it alone.
            if !isFloating {
                dismiss()
            }
        }
        #if os(macOS)
        .background(
            // Agent-chat panels need the same comfortable default size as the
            // dedicated `AgentChatWindow`; otherwise an empty chat can collapse
            // the workspace panel window to an unusable size. Sizes come from
            // the shared `floatingMinSize`/`floatingDefaultSize` so the frame
            // store clamps to the same floor.
            Group {
                switch target.kind {
                case .agentChat, .damBrowser:
                    WindowSizeConfigurator(
                        minSize: target.kind.floatingMinSize,
                        defaultSize: target.kind.floatingDefaultSize,
                        backgroundColor: nil
                    )
                default:
                    EmptyView()
                }
            }
        )
        // Restore this panel's saved frame (and start recording moves/resizes)
        // so window positions survive relaunches and workspace-layout recalls.
        .background(WindowFrameConfigurator(
            kind: target.kind,
            appsViewMode: target.kind == .appLauncher ? appsViewMode : nil
        ))
        .background(
            WindowCloseObserver {
                // The user closed this window (red close button, Cmd+W,
                // ⌘Q, etc.) — the panel is now genuinely closed, so clear it
                // from `floatingPanels` too. Otherwise it'd stay marked
                // "open" forever (stale sidebar indicator, and `open(_:)`
                // would silently no-op on any future attempt to reopen it).
                // A panel already closed from elsewhere is left untouched.
                if layout.isFloating(target.kind) {
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

    private var header: some View {
        let headerBackground = theme.panelAccent(for: target.kind).opacity(0.2)

        return HStack(spacing: 6) {
            // The window itself is draggable by its title bar; the header
            // only carries identity and controls.
            Image(systemName: target.kind.icon)
                .font(.caption)
                .foregroundStyle(theme.panelAccent(for: target.kind))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(headerBackground)
        // Keep the controls on top so they survive tiny windows.
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                if case .agentChat(let id) = target.kind {
                    ChatPanelHeaderToolbar(agentID: id)
                }

                if target.kind == .appLauncher {
                    AppsLauncherPanel().headerToolbar
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

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(headerBackground)
        }
    }
}


