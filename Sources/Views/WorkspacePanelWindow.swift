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
        #if os(macOS)
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
        #endif
    }

    private var title: String {
        if case .agentChat(let id) = target.kind {
            return workspace.agent(id: id)?.name ?? "Agent"
        }
        if case .plugin(let id) = target.kind {
            return pluginService.manifest(id: id)?.name ?? "Plugin"
        }
        return target.kind.staticDisplayName ?? "Panel"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: target.kind.icon)
                .font(.caption)
                .foregroundStyle(theme.panelAccent(for: target.kind))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

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

            Button {
                didDock = true
                layout.dock(target.kind)
                dismiss()
            } label: {
                Label("Dock", systemImage: "rectangle.on.rectangle")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Dock into the main window")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.panelAccent(for: target.kind).opacity(0.2))
    }
}

#if os(macOS)
/// Invokes `onClose` exactly once when the hosting `NSWindow` actually closes
/// (red close button, Cmd+W, app quit, etc.) — SwiftUI's `.onDisappear` isn't
/// reliably tied to window-close specifically, so this observes
/// `NSWindow.willCloseNotification` directly instead.
private struct WindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private let onClose: () -> Void
        private var observer: NSObjectProtocol?
        private weak var observedWindow: NSWindow?

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func attach(to window: NSWindow?) {
            guard let window, window !== observedWindow else { return }
            detach()
            observedWindow = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [onClose] _ in
                onClose()
            }
        }

        func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            observedWindow = nil
        }
    }
}
#endif
