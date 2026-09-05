import SwiftUI

// MARK: - Journal Page

/// Manual journal entries for double-entry bookkeeping. Each entry has two or
/// more lines that must balance (total debits == total credits).
struct JournalPage: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @State private var showEditor = false
    @State private var editingEntry: BooksJournalEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(viewModel.journalEntries) { entry in
                JournalRow(entry: entry, theme: theme)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingEntry = entry
                        showEditor = true
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.chatBackground)
        }
        .sheet(isPresented: $showEditor) {
            JournalEditorSheet(
                viewModel: viewModel,
                entry: editingEntry,
                isPresented: $showEditor)
        }
    }

    private var header: some View {
        HStack {
            Text("Journal Entries")
                .font(.headline)
            Spacer()
            Button {
                editingEntry = nil
                showEditor = true
            } label: {
                Label("New Entry", systemImage: "plus")
            }
        }
        .padding()
        .background(theme.secondaryBackground)
    }
}

private struct JournalRow: View {
    let entry: BooksJournalEntry
    let theme: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.reference ?? "Journal")
                    .font(.body.weight(.medium))
                    .foregroundStyle(theme.chatText)
                Spacer()
                Text(entry.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(entry.memo)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Journal editor

private struct JournalEditorSheet: View {
    @Bindable var viewModel: BooksViewModel
    @Environment(ThemeStore.self) private var theme
    @Binding var isPresented: Bool

    @State private var entry: BooksJournalEntry
    @State private var lines: [JournalLineForm]
    private let isNew: Bool

    init(viewModel: BooksViewModel, entry: BooksJournalEntry?, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        self.isNew = entry == nil
        self._entry = State(initialValue: entry ?? BooksJournalEntry(
            id: nil, date: Date(), reference: nil, memo: "", currency: "AUD",
            createdAt: Date(), updatedAt: Date()))
        self._lines = State(initialValue: [
            JournalLineForm(accountCode: "", debit: 0, credit: 0, description: nil),
            JournalLineForm(accountCode: "", debit: 0, credit: 0, description: nil)
        ])
    }

    private var totalDebits: Double { lines.reduce(0) { $0 + $1.debit } }
    private var totalCredits: Double { lines.reduce(0) { $0 + $1.credit } }
    private var isBalanced: Bool { abs(totalDebits - totalCredits) < 0.005 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "New Journal Entry" : "Edit Journal Entry")
                    .font(.headline)
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.borderless)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(entry.memo.isEmpty || lines.count < 2 || !isBalanced)
            }
            .padding()
            .background(theme.secondaryBackground)

            Form {
                DatePicker("Date", selection: $entry.date, displayedComponents: .date)
                TextField("Reference", text: binding(for: $entry.reference))
                TextField("Memo", text: $entry.memo)

                Section {
                    HStack {
                        Text("Account")
                            .frame(width: 120, alignment: .leading)
                        Text("Debit")
                            .frame(width: 90, alignment: .trailing)
                        Text("Credit")
                            .frame(width: 90, alignment: .trailing)
                        Text("Description")
                            .frame(minWidth: 120, alignment: .leading)
                        Spacer().frame(width: 30)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    ForEach($lines) { $line in
                        HStack {
                            TextField("Code", text: $line.accountCode)
                                .frame(width: 120)
                            TextField("0.00", value: $line.debit, format: .number)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                            TextField("0.00", value: $line.credit, format: .number)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                            TextField("Note", text: binding(for: $line.description))
                                .frame(minWidth: 120)
                            Button {
                                deleteLine(line)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 30)
                        }
                    }

                    Button {
                        lines.append(JournalLineForm(accountCode: "", debit: 0, credit: 0, description: nil))
                    } label: {
                        Label("Add line", systemImage: "plus")
                    }

                    HStack {
                        Text("Total debits: \(totalDebits, format: .currency(code: entry.currency))")
                        Spacer()
                        Text("Total credits: \(totalCredits, format: .currency(code: entry.currency))")
                    }
                    .font(.caption)
                    .foregroundStyle(isBalanced ? .green : .red)
                }
            }
            .padding()
            .frame(minWidth: 560, idealWidth: 720)

            Spacer()
        }
        .background(theme.chatBackground)
    }

    private func binding(for optional: Binding<String?>) -> Binding<String> {
        Binding(
            get: { optional.wrappedValue ?? "" },
            set: { optional.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func deleteLine(_ line: JournalLineForm) {
        lines.removeAll { $0.id == line.id }
    }

    private func save() {
        let journalLines = lines.map {
            BooksJournalLine(
                id: nil, journalEntryID: entry.id ?? 0,
                accountCode: $0.accountCode, debit: $0.debit,
                credit: $0.credit, description: $0.description)
        }
        Task {
            var mutable = entry
            await viewModel.saveJournalEntry(&mutable, lines: journalLines)
            isPresented = false
        }
    }
}

private struct JournalLineForm: Identifiable {
    let id = UUID()
    var accountCode: String
    var debit: Double
    var credit: Double
    var description: String?
}
