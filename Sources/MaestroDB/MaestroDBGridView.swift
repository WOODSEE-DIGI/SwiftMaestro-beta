import SwiftUI

// MARK: - MaestroDB Grid View
//
// Airtable-style data grid: pinned header row, per-type cell editors,
// sort cycling on headers, add-row footer, field context menus.

struct MaestroDBGridView: View {
    @Bindable var viewModel: MaestroDBViewModel
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section(header: headerRow) {
                    ForEach(viewModel.rows) { row in
                        gridRow(row)
                        Divider().opacity(0.4)
                    }
                    addRowButton
                }
            }
            // Fill the viewport so short tables pin to the top — without this
            // the ScrollView vertically centers content smaller than itself.
            .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme.chatBackground)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .font(.caption2)
                .foregroundStyle(theme.chatText.opacity(0.35))
                .frame(width: 40, alignment: .center)
            ForEach(viewModel.fields) { field in
                fieldHeader(field)
            }
            Spacer(minLength: 60)
        }
        .padding(.vertical, 6)
        .background(theme.secondaryBackground)
    }

    private func fieldHeader(_ field: DBField) -> some View {
        HStack(spacing: 4) {
            Image(systemName: field.type.icon)
                .font(.caption2)
                .foregroundStyle(theme.chatText.opacity(0.6))
            Text(field.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            if let sort = viewModel.sort, sort.fieldID == field.id {
                Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.cycleSort(on: field.id) }
        .frame(width: Self.width(for: field), alignment: .leading)
        .padding(.horizontal, 8)
        .contextMenu { fieldMenu(field) }
        .help("Click to sort. Right-click for field options.")
    }

    @ViewBuilder
    private func fieldMenu(_ field: DBField) -> some View {
        Button("Rename…") {
            let newName = NSAlert.prompt("Rename field", defaultValue: field.name)
            if let newName, !newName.isEmpty {
                var updated = field
                updated.name = newName
                Task { await viewModel.updateField(updated) }
            }
        }
        if field.type == .select || field.type == .multiSelect {
            Button("Add option…") {
                let option = NSAlert.prompt("New option for '\(field.name)'", defaultValue: "")
                if let option, !option.isEmpty {
                    Task { await viewModel.addFieldOption(field.id, option: option) }
                }
            }
        }
        Divider()
        Button("Delete field", role: .destructive) {
            Task { await viewModel.deleteField(field.id) }
        }
    }

    // MARK: - Rows

    private func gridRow(_ row: DBRow) -> some View {
        HStack(spacing: 0) {
            Text("\(row.position + 1)")
                .font(.caption2)
                .foregroundStyle(theme.chatText.opacity(0.35))
                .frame(width: 40, alignment: .center)
                .contextMenu {
                    Button("Delete row", role: .destructive) {
                        Task { await viewModel.deleteRow(row.id) }
                    }
                }
            ForEach(viewModel.fields) { field in
                MaestroDBCellView(
                    field: field, row: row,
                    relation: viewModel.relationData[field.id]
                ) { value in
                    viewModel.setCell(rowID: row.id, fieldID: field.id, value: value)
                }
                .frame(width: Self.width(for: field), alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            Spacer(minLength: 60)
        }
        .contentShape(Rectangle())
    }

    private var addRowButton: some View {
        Button { Task { await viewModel.addRow() } } label: {
            Label("Add row", systemImage: "plus")
                .font(.caption)
                .foregroundStyle(theme.chatText.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Column widths

    static func width(for field: DBField) -> CGFloat {
        switch field.type {
        case .text: return 200
        case .longText: return 240
        case .number: return 100
        case .checkbox: return 70
        case .date: return 150
        case .select: return 150
        case .multiSelect: return 180
        case .url, .email, .phone: return 170
        case .rating: return 120
        case .relation: return 170
        case .attachment: return 150
        }
    }
}

// MARK: - Alert prompt helper

extension NSAlert {
    /// Small synchronous text prompt used for rename/option micro-flows.
    static func prompt(_ title: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
