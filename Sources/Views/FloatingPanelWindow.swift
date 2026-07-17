import SwiftUI

/// Identifier for a floating panel window. Stores which panel type is shown
/// and which agent's data to display (for Tasks panel).
struct FloatingPanelWindowID: Hashable, Codable {
    let panelType: String
    let agentID: UUID?
}

/// Content view for a floating panel window. Reads shared stores and renders
/// the same content as the docked version.
struct FloatingPanelWindowView: View {
    let target: FloatingPanelWindowID

    @Environment(TodoStore.self) private var todoStore
    @Environment(PlanStore.self) private var planStore
    @Environment(ThemeStore.self) private var theme
    @State private var layoutState = PanelLayoutState.shared
    /// Keep this window in front of all others. Opt-in, off by default.
    @State private var isPinnedToFront = false

    private var panelType: PanelType? {
        PanelType(rawValue: target.panelType)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: panelType?.icon ?? "rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(panelType?.displayName ?? "Panel")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

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
                    if let type = panelType {
                        layoutState.dock(type)
                    }
                } label: {
                    Label("Dock", systemImage: "rectangle.on.rectangle")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Dock back to main window")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0)))

            Divider()

            // Panel content
            switch panelType {
            case .tasks:
                floatingTasksContent
            case .plans:
                floatingPlansContent
            default:
                Text("Unknown panel")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1.0)))
        #if os(macOS)
        .background(WindowPinConfigurator(isPinned: isPinnedToFront))
        #endif
    }

    // MARK: - Tasks Content

    @ViewBuilder
    private var floatingTasksContent: some View {
        let agentID = target.agentID ?? UUID()
        let todos = todoStore.lists[agentID] ?? []
        let done = todos.filter { $0.done }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Text("\(done)/\(todos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { todoStore.clear(for: agentID) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Clear this task list")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(todos) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? .green : .secondary)
                            Text(item.title)
                                .strikethrough(item.done, color: .secondary)
                                .foregroundStyle(item.done ? Color.secondary : theme.tasksText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(.callout)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Plans Content

    @ViewBuilder
    private var floatingPlansContent: some View {
        let agentID = target.agentID ?? UUID()
        let items = planStore.plans(in: .agent(agentID))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { plan in
                        Text(plan.title)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(theme.plansCardText)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                theme.accent,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
