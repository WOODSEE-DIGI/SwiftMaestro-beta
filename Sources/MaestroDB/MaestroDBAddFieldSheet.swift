import SwiftUI

// MARK: - MaestroDB Add Field Sheet
//
// Name + type picker (+ select options editor, + relation target picker) for
// new fields.

struct MaestroDBAddFieldSheet: View {
    /// Tables offered as relation link targets (the current base's tables;
    /// self-linking is allowed).
    let tables: [DBTable]
    let onAdd: (String, DBFieldType, [String], [String: String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var theme
    @State private var name = ""
    @State private var type: DBFieldType = .text
    @State private var optionsText = ""
    @State private var linkTableID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Field")
                .font(.headline)

            TextField("Field name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Type", selection: $type) {
                ForEach(DBFieldType.uiSupported) { fieldType in
                    Label(fieldType.displayName, systemImage: fieldType.icon).tag(fieldType)
                }
            }
            .pickerStyle(.menu)

            if type == .select || type == .multiSelect {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Options (one per line)")
                        .font(.caption)
                        .foregroundStyle(theme.chatText.opacity(0.6))
                    TextEditor(text: $optionsText)
                        .font(.callout)
                        .frame(height: 90)
                        .border(.quaternary)
                }
            }

            if type == .relation {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Link to table")
                        .font(.caption)
                        .foregroundStyle(theme.chatText.opacity(0.6))
                    Picker("Link to table", selection: $linkTableID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(tables) { table in
                            Label(table.name, systemImage: "tablecells").tag(String?.some(table.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Field") {
                    let options = optionsText
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    var config: [String: String] = [:]
                    if type == .relation, let linkTableID {
                        config["table"] = linkTableID
                    }
                    onAdd(name.trimmingCharacters(in: .whitespaces), type, options, config)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty
                        || (type == .relation && linkTableID == nil))
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
