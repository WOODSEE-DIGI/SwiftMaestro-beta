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

    @State private var layout = WorkspaceLayoutState.shared
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            content()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            // Drag grip: the obvious handle for moving the whole tile.
            if isDraggable {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(theme.panelAccent(for: kind).opacity(0.85))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
                    .draggable(WorkspacePanelTransfer(kind: kind))
                    .help("Drag to move this panel")
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
    }
}
