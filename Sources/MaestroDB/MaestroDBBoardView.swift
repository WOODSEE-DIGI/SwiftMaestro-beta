import SwiftUI

// MARK: - MaestroDB Board View
//
// Board mode for a MaestroDB table — renders the SHARED KanbanBoardView from
// the Kanban app via the KanbanStore write-through bridge. No second kanban:
// same views, same store mutations, MaestroDB as the data backend.

struct MaestroDBBoardView: View {
    @Bindable var viewModel: MaestroDBViewModel
    @Environment(KanbanStore.self) private var store
    @Environment(ThemeStore.self) private var theme

    @State private var searchQuery = ""
    @State private var editingCard: CardEditRequest?

    private var selectFields: [DBField] {
        viewModel.fields.filter { $0.type == .select }
    }

    private var link: MaestroBoardLink? {
        // Touch store.boards unconditionally: link creation happens via THIS
        // view's picker, and without a tracked dependency on boards the store's
        // rebuildBoards() can't invalidate us — the board appeared only after
        // switching tables away and back (which re-rendered for other reasons).
        _ = store.boards
        guard let tableID = viewModel.selectedTableID else { return nil }
        return store.maestroLink(forTable: tableID)
    }

    private var board: KanbanBoard? {
        guard let link else { return nil }
        return store.boards.first(where: { $0.id == link.boardID }) ?? store.maestroProject(link)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let link, let board {
                boardHeader(link: link)
                Divider()
                KanbanBoardView(
                    board: board,
                    searchQuery: searchQuery,
                    onEditCard: { card, columnId in
                        editingCard = CardEditRequest(card: card, columnId: columnId, isNew: false)
                    },
                    onAddCard: { columnId in
                        editingCard = CardEditRequest(card: KanbanCard(title: ""), columnId: columnId, isNew: true)
                    }
                )
            } else if selectFields.isEmpty {
                ContentUnavailableView(
                    "Board Needs a Select Field",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Board view groups cards by a single-select field. Switch to the grid and add one — e.g. Status: Booked, Shooting, Delivered.")
                )
            } else {
                groupFieldPicker
            }
        }
        .sheet(item: $editingCard) { request in
            if let link {
                KanbanCardEditorSheet(boardId: link.boardID, request: request)
            }
        }
    }

    // MARK: - Header (linked state)

    private func boardHeader(link: MaestroBoardLink) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.chatText.opacity(0.6))
            TextField("Filter cards…", text: $searchQuery)
                .textFieldStyle(.plain)
                .frame(maxWidth: 200)

            Spacer()

            Text("Group by:")
                .font(.caption)
                .foregroundStyle(theme.chatText.opacity(0.6))
            Picker("Group by", selection: Binding(
                get: { link.groupFieldID },
                set: { newFieldID in
                    guard let tableID = viewModel.selectedTableID else { return }
                    _ = try? store.relinkMaestroTable(tableID: tableID, newGroupFieldID: newFieldID)
                }
            )) {
                ForEach(selectFields) { field in
                    Text(field.name).tag(field.id)
                }
            }
            .labelsHidden()
            .fixedSize()

            Menu {
                Button("Unlink Board (keep table data)") {
                    store.unlinkMaestroBoard(link.boardID)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground)
    }

    // MARK: - Group field picker (unlinked state)

    private var groupFieldPicker: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 36))
                .foregroundStyle(theme.chatText.opacity(0.6))
            Text("Group by which select field?")
                .font(.headline)
            Text("The board groups cards by a single-select field — its options become the columns.")
                .font(.caption)
                .foregroundStyle(theme.chatText.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 8) {
                ForEach(selectFields) { field in
                    Button(field.name) {
                        guard let tableID = viewModel.selectedTableID else { return }
                        _ = try? store.linkMaestroTable(tableID: tableID, groupFieldID: field.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
