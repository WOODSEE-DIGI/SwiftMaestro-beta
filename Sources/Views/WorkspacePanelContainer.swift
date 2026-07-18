import SwiftUI

// MARK: - Workspace Panel Container
//
// Wraps a top-level workspace panel (an agent's chat, Notes.md, Apple Notes,
// Calendar, Reminders, Contacts, Canvas, or Kanban) with a lightweight header:
// icon + title, a "Move Left/Right" context menu for reordering, and a close
// button. The multi-panel analogue of `PanelContainer`, which serves the same
// role one level down for Plans/Tasks/Terminal inside a single agent's chat.
struct WorkspacePanelContainer<Content: View>: View {

    let kind: WorkspacePanelKind
    let title: String
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
            Image(systemName: kind.icon)
                .font(.caption)
                .foregroundStyle(theme.panelAccent(for: kind))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

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
        // Left/Right — reorder within this panel's own row.
        if let column = layout.columnPosition(of: kind) {
            if column.index > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layout.moveWithinRow(kind, to: column.index - 1)
                    }
                } label: {
                    Label("Move Left", systemImage: "arrow.left")
                }
            }
            if column.index < column.count - 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layout.moveWithinRow(kind, to: column.index + 2)
                    }
                } label: {
                    Label("Move Right", systemImage: "arrow.right")
                }
            }
        }

        Divider()

        // Up/Down — merge into the adjacent row (manual quadrant control).
        if let row = layout.rowPosition(of: kind) {
            if row.index > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layout.moveToAdjacentRow(kind, direction: .up)
                    }
                } label: {
                    Label("Move Up a Row", systemImage: "arrow.up")
                }
            }
            if row.index < row.count - 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layout.moveToAdjacentRow(kind, direction: .down)
                    }
                } label: {
                    Label("Move Down a Row", systemImage: "arrow.down")
                }
            }
        }

        // Only offer "split into its own row" if it currently shares a row
        // with something else.
        if let column = layout.columnPosition(of: kind), column.count > 1 {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    layout.sendToNewRow(kind)
                }
            } label: {
                Label("Move to New Row", systemImage: "rectangle.split.2x1")
            }
        }

        if let onFloat {
            Divider()
            Button {
                layout.float(kind)
                onFloat(kind)
            } label: {
                Label("Pop Out to Window", systemImage: "rectangle.expand.vertical")
            }
        }
    }
}
