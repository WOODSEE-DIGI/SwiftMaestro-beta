import SwiftUI

// MARK: - MaestroDB Cell View
//
// One grid cell: the right inline editor for each field type. Text-ish cells
// keep local editing state and commit on submit/focus loss so typing never
// round-trips the database per keystroke.

struct MaestroDBCellView: View {
    let field: DBField
    let row: DBRow
    let onCommit: (String) -> Void

    @State private var draft: String?
    @FocusState private var focused: Bool
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if draft == nil && isTextual { draft = row.value(for: field.id) }
                focused = true
            }
    }

    @ViewBuilder
    private var content: some View {
        switch field.type {
        case .text, .longText, .url, .email, .phone:
            textEditor
        case .number:
            numberEditor
        case .checkbox:
            checkboxEditor
        case .date:
            dateEditor
        case .select:
            selectEditor
        case .multiSelect:
            multiSelectEditor
        case .rating:
            ratingEditor
        case .relation, .attachment:
            Text(row.display(for: field))
                .font(.callout)
                .foregroundStyle(theme.chatText.opacity(0.35))
        }
    }

    private var isTextual: Bool {
        [.text, .longText, .url, .email, .phone, .number].contains(field.type)
    }

    // MARK: Text-ish

    private var textEditor: some View {
        Group {
            if let draft {
                TextField("", text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                let value = row.value(for: field.id)
                if value.isEmpty {
                    Text(" ").frame(maxWidth: .infinity, alignment: .leading)
                } else if field.type == .url, let url = URL(string: value) {
                    Link(value, destination: url)
                        .font(.callout)
                        .lineLimit(1)
                } else {
                    Text(value)
                        .font(.callout)
                        .lineLimit(field.type == .longText ? 2 : 1)
                        .foregroundStyle(theme.chatText)
                }
            }
        }
    }

    private var numberEditor: some View {
        Group {
            if let draft {
                TextField("", text: Binding(get: { draft }, set: { self.draft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.callout.monospacedDigit())
                    .focused($focused)
                    .onSubmit { commitNumber() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commitNumber() }
                    }
            } else if let number = row.number(for: field.id) {
                Text(DBRow.store(number))
                    .font(.callout.monospacedDigit())
            } else {
                Text(" ")
            }
        }
    }

    private func commit() {
        guard let draft else { return }
        let value = draft.trimmingCharacters(in: .whitespaces)
        if value != row.value(for: field.id) { onCommit(value) }
        self.draft = nil
    }

    private func commitNumber() {
        guard let draft else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if !row.value(for: field.id).isEmpty { onCommit("") }
        } else if let number = Double(trimmed.replacingOccurrences(of: ",", with: "")) {
            if DBRow.store(number) != row.value(for: field.id) { onCommit(DBRow.store(number)) }
        }
        self.draft = nil
    }

    // MARK: Checkbox

    private var checkboxEditor: some View {
        Toggle("", isOn: Binding(
            get: { row.bool(for: field.id) },
            set: { onCommit(DBRow.store($0)) }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
    }

    // MARK: Date

    private var dateEditor: some View {
        HStack(spacing: 4) {
            DatePicker(
                "",
                selection: Binding(
                    get: { row.date(for: field.id) ?? Date() },
                    set: { onCommit(DBRow.store($0)) }
                ),
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.field)
            if row.date(for: field.id) != nil {
                Button { onCommit("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.chatText.opacity(0.35))
                .help("Clear date")
            }
        }
    }

    // MARK: Select

    private var selectEditor: some View {
        Menu {
            ForEach(field.options, id: \.self) { option in
                Button(option) { onCommit(option) }
            }
            if !field.options.isEmpty { Divider() }
            Button("Add option…") {
                let option = NSAlert.prompt("New option for '\(field.name)'", defaultValue: "")
                if let option, !option.isEmpty { onCommit(option) }
            }
            if !row.value(for: field.id).isEmpty {
                Divider()
                Button("Clear") { onCommit("") }
            }
        } label: {
            HStack(spacing: 4) {
                let value = row.value(for: field.id)
                if value.isEmpty {
                    Text("Select…").font(.callout).foregroundStyle(theme.chatText.opacity(0.35))
                } else {
                    Text(value)
                        .font(.callout)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.accent.opacity(0.15))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.chatText.opacity(0.35))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Multi select

    private var multiSelectEditor: some View {
        Menu {
            ForEach(field.options, id: \.self) { option in
                let selected = row.multiValues(for: field.id).contains(option)
                Button {
                    var values = row.multiValues(for: field.id)
                    if selected { values.removeAll { $0 == option } }
                    else { values.append(option) }
                    onCommit(DBRow.store(multi: values))
                } label: {
                    Label(option, systemImage: selected ? "checkmark" : "")
                }
            }
            Divider()
            Button("Add option…") {
                let option = NSAlert.prompt("New option for '\(field.name)'", defaultValue: "")
                if let option, !option.isEmpty {
                    var values = row.multiValues(for: field.id)
                    values.append(option)
                    onCommit(DBRow.store(multi: values))
                }
            }
            if !row.multiValues(for: field.id).isEmpty {
                Divider()
                Button("Clear all") { onCommit("") }
            }
        } label: {
            HStack(spacing: 4) {
                let values = row.multiValues(for: field.id)
                if values.isEmpty {
                    Text("Select…").font(.callout).foregroundStyle(theme.chatText.opacity(0.35))
                } else {
                    Text(values.joined(separator: ", "))
                        .font(.callout)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.chatText.opacity(0.35))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Rating

    private var ratingEditor: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= row.rating(for: field.id) ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(star <= row.rating(for: field.id) ? .yellow : .secondary.opacity(0.4))
                    .onTapGesture {
                        let newValue = (star == row.rating(for: field.id)) ? 0 : star
                        onCommit(newValue == 0 ? "" : String(newValue))
                    }
            }
        }
    }
}
