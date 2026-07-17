import SwiftUI

/// Resolves a `WorkspacePanelKind` to its actual content view. Shared between
/// the docked grid (`ContentView`) and floating panel windows
/// (`WorkspacePanelWindowView`) so both render identically and neither
/// duplicates this switch.
struct WorkspacePanelContentView: View {
    let kind: WorkspacePanelKind

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(NotesViewModel.self) private var notesViewModel

    var body: some View {
        switch kind {
        case .notesMD:
            NotesView(viewModel: notesViewModel)
        case .appleNotes:
            AppleNotesView()
        case .calendar:
            CalendarView()
        case .reminders:
            RemindersView()
        case .contacts:
            ContactsView()
        case .canvas:
            if #available(macOS 26.0, *) {
                CanvasView()
            } else {
                CanvasFallbackView()
            }
        case .kanban:
            KanbanView()
        case .terminal:
            TerminalView()
        case .agentChat(let id):
            if let agent = workspace.agent(id: id), let cache = ChatViewModelCache.shared {
                ChatView(vm: cache.viewModel(
                    for: agent,
                    projectName: workspace.projectName(for: agent)))
                    .id(agent.id)
            } else {
                ContentUnavailableView(
                    "Agent Not Found",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("This agent no longer exists")
                )
            }
        }
    }
}
