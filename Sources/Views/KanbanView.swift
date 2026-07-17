import SwiftUI

// MARK: - Kanban view

struct KanbanView: View {
    @Environment(KanbanStore.self) private var store
    @Environment(ThemeStore.self) private var theme
    @State private var selectedBoardId: UUID?
    @State private var isAddingBoard = false
    @State private var newBoardName = ""
    @State private var editingCard: CardEditRequest?
    @State private var isAddingColumn = false
    @State private var newColumnName = ""
    @State private var searchQuery = ""

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            if store.boards.isEmpty {
                emptyBoardsView
            } else if let board = selectedBoard {
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
            } else {
                ContentUnavailableView(
                    "Select a Board",
                    systemImage: "rectangle.3.group",
                    description: Text("Choose a kanban board from the picker above."))
            }
        }
        .sheet(item: $editingCard) { request in
            KanbanCardEditorSheet(
                boardId: selectedBoardId,
                request: request
            )
        }
        .sheet(isPresented: $isAddingBoard) {
            newBoardSheet
        }
        .sheet(isPresented: $isAddingColumn) {
            newColumnSheet
        }
        .onAppear {
            if selectedBoardId == nil, let first = store.boards.first {
                selectedBoardId = first.id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Kanban")
                .font(.headline)

            Picker("Board", selection: $selectedBoardId) {
                ForEach(store.boards) { board in
                    Text(board.name).tag(Optional(board.id))
                }
            }
            .labelsHidden()
            .frame(minWidth: 160, maxWidth: 260)

            Button {
                isAddingBoard = true
            } label: {
                Label("New Board", systemImage: "plus")
            }

            if selectedBoard != nil {
                Button {
                    isAddingColumn = true
                } label: {
                    Label("Column", systemImage: "plus.rectangle.on.rectangle")
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search cards", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            if let board = selectedBoard {
                Button {
                    _ = store.duplicate(board)
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    if let id = selectedBoardId {
                        store.delete(id)
                        selectedBoardId = store.boards.first?.id
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var selectedBoard: KanbanBoard? {
        guard let id = selectedBoardId else { return nil }
        return store.boards.first { $0.id == id }
    }

    private var emptyBoardsView: some View {
        ContentUnavailableView {
            Label("No Kanban Boards", systemImage: "rectangle.3.group")
        } description: {
            Text("Create a board to start scheduling tasks.")
        } actions: {
            Button("Create Board") { isAddingBoard = true }
        }
    }

    // MARK: - Sheets

    private var newBoardSheet: some View {
        VStack(spacing: 16) {
            Text("New Kanban Board")
                .font(.headline)
            TextField("Board name", text: $newBoardName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Button("Cancel", role: .cancel) {
                    isAddingBoard = false
                    newBoardName = ""
                }
                Button("Create") {
                    let name = newBoardName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let board = store.createBoard(name: name)
                    selectedBoardId = board.id
                    isAddingBoard = false
                    newBoardName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newBoardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }

    private var newColumnSheet: some View {
        VStack(spacing: 16) {
            Text("New Column")
                .font(.headline)
            TextField("Column name", text: $newColumnName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Button("Cancel", role: .cancel) {
                    isAddingColumn = false
                    newColumnName = ""
                }
                Button("Create") {
                    let name = newColumnName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, let boardId = selectedBoardId else { return }
                    store.addColumn(to: boardId, title: name)
                    isAddingColumn = false
                    newColumnName = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newColumnName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

// MARK: - Board view

private struct KanbanBoardView: View {
    @Environment(KanbanStore.self) private var store
    @Environment(ThemeStore.self) private var theme
    let board: KanbanBoard
    let searchQuery: String
    let onEditCard: (KanbanCard, UUID) -> Void
    let onAddCard: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(board.columns) { column in
                    KanbanColumnView(
                        boardId: board.id,
                        column: column,
                        searchQuery: searchQuery,
                        onEditCard: onEditCard,
                        onAddCard: onAddCard
                    )
                }
            }
            .padding()
            .frame(minHeight: 400)
        }
        .background(theme.chatBackground)
    }
}

// MARK: - Column view

private struct KanbanColumnView: View {
    @Environment(KanbanStore.self) private var store
    @Environment(ThemeStore.self) private var theme
    let boardId: UUID
    let column: KanbanColumn
    let searchQuery: String
    let onEditCard: (KanbanCard, UUID) -> Void
    let onAddCard: (UUID) -> Void

    private var filteredCards: [KanbanCard] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return column.cards }
        return column.cards.filter {
            $0.title.lowercased().contains(query)
            || $0.description.lowercased().contains(query)
            || $0.tags.contains { $0.lowercased().contains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filteredCards) { card in
                        KanbanCardView(
                            boardId: boardId,
                            card: card,
                            onEdit: { onEditCard(card, column.id) }
                        )
                    }
                }
                .padding(8)
            }

            Button {
                onAddCard(column.id)
            } label: {
                Label("Add Card", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(width: 280)
        .background(theme.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(column.color?.swiftUIColor ?? .clear, lineWidth: 2)
        )
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: String.self) { string, _ in
                guard let payload = string,
                      let cardId = UUID(uuidString: payload) else { return }
                Task { @MainActor in
                    store.moveCard(cardId, toColumn: column.id, toIndex: 0, in: boardId)
                }
            }
            return true
        }
    }

    private var columnHeader: some View {
        HStack {
            if let color = column.color {
                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 10, height: 10)
            }
            Text(column.title)
                .font(.headline)
            Spacer()
            Text("\(column.cards.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("Delete Column", role: .destructive) {
                    store.deleteColumn(column.id, from: boardId)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Card view

private struct KanbanCardView: View {
    @Environment(KanbanStore.self) private var store
    @Environment(ThemeStore.self) private var theme
    let boardId: UUID
    let card: KanbanCard
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                priorityBadge
            }

            if !card.description.isEmpty {
                Text(card.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if let dueDate = card.dueDate {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text(dueDate, style: .date)
                        .font(.caption2)
                }
                .foregroundStyle(card.isOverdue ? .red : .secondary)
                .fontWeight(card.isOverdue ? .bold : .regular)
            }

            if !card.tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(card.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(10)
        .background(Color(theme.userBubble).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onEdit() }
        .onDrag {
            NSItemProvider(object: card.id.uuidString as NSString)
        }
        .contextMenu {
            Button("Edit") { onEdit() }
            Button("Delete", role: .destructive) {
                store.deleteCard(card.id, from: boardId)
            }
        }
    }

    private var priorityBadge: some View {
        Text(card.priority.displayName)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(card.priority.color.opacity(0.2))
            .foregroundStyle(card.priority.color)
            .clipShape(Capsule())
    }
}

// MARK: - Card edit request

private struct CardEditRequest: Identifiable {
    let id = UUID()
    let card: KanbanCard
    let columnId: UUID
    let isNew: Bool
}

// MARK: - Card editor sheet

private struct KanbanCardEditorSheet: View {
    @Environment(KanbanStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let boardId: UUID?
    let request: CardEditRequest

    @State private var title: String
    @State private var description: String
    @State private var priority: KanbanPriority
    @State private var dueDate: Date
    @State private var hasDueDate: Bool
    @State private var tagInput: String
    @State private var tags: [String]

    init(boardId: UUID?, request: CardEditRequest) {
        self.boardId = boardId
        self.request = request
        let card = request.card
        _title = State(initialValue: card.title)
        _description = State(initialValue: card.description)
        _priority = State(initialValue: card.priority)
        _dueDate = State(initialValue: card.dueDate ?? Date())
        _hasDueDate = State(initialValue: card.dueDate != nil)
        _tagInput = State(initialValue: "")
        _tags = State(initialValue: card.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.isNew ? "New Card" : "Edit Card")
                .font(.headline)

            Form {
                TextField("Title", text: $title)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(3...6)

                Picker("Priority", selection: $priority) {
                    ForEach(KanbanPriority.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }

                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Due", selection: $dueDate, displayedComponents: .date)
                }

                HStack {
                    TextField("Add tag", text: $tagInput)
                    Button("Add") {
                        let tag = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        if !tag.isEmpty, !tags.contains(tag) {
                            tags.append(tag)
                        }
                        tagInput = ""
                    }
                    .disabled(tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                Button {
                                    tags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 460, height: 520)
    }

    private func save() {
        guard let boardId else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        var updated = request.card
        updated.title = trimmedTitle
        updated.description = description
        updated.priority = priority
        updated.dueDate = hasDueDate ? dueDate : nil
        updated.tags = tags

        if request.isNew {
            store.addCard(updated, toColumn: request.columnId, in: boardId)
        } else {
            store.updateCard(updated, in: boardId)
        }
        dismiss()
    }
}

// MARK: - Flow layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? .infinity, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                          proposal: .unspecified)
        }
    }

    private struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth, x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }
            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}

