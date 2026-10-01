import SwiftUI

/// Opencode-style collapsible todo dock that lives above the chat input bar.
/// Shows a one-line progress preview when collapsed and an expandable checklist
/// when open.
struct ChatTodoDock: View {
    @Environment(ThemeStore.self) private var theme
    let todos: [TodoItem]
    let collapsed: Bool
    let onToggle: () -> Void
    let onClear: () -> Void

    private var doneCount: Int { todos.filter(\.done).count }
    private var activeTodo: TodoItem? {
        todos.first { !$0.done }
            ?? todos.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if !todos.isEmpty {
                    Text("\(doneCount)/\(todos.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.accent)
                }

                if collapsed, let active = activeTodo {
                    Text(active.title)
                        .font(.caption)
                        .foregroundStyle(theme.chatSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if !collapsed {
                    Text("Tasks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.chatText)
                }

                Spacer(minLength: 0)

                if !todos.isEmpty {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.chatSecondaryText)
                    .help("Clear task list")
                }

                Button {
                    onToggle()
                } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.chatSecondaryText)
                .help(collapsed ? "Show tasks" : "Hide tasks")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if !collapsed && !todos.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(todos) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.done ? .green : theme.chatSecondaryText.opacity(0.55))
                                Text(MaestroTools.sanitizeModelText(item.title))
                                    .font(.callout)
                                    .strikethrough(item.done, color: theme.chatSecondaryText.opacity(0.55))
                                    .foregroundStyle(item.done ? theme.chatSecondaryText.opacity(0.55) : theme.chatText)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 180)
            }
        }
        .background(theme.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.chatSecondaryText.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.easeInOut(duration: 0.2), value: collapsed)
        .animation(.easeInOut(duration: 0.2), value: todos.count)
    }
}
