import SwiftUI

// MARK: - MaestroDB Add Field Sheet
//
// Name + type picker (+ select options editor) for new fields.

struct MaestroDBAddFieldSheet: View {
    let onAdd: (String, DBFieldType, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeStore.self) private var theme
    @State private var name = ""
    @State private var type: DBFieldType = .text
    @State private var optionsText = ""

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

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Field") {
                    let options = optionsText
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    onAdd(name.trimmingCharacters(in: .whitespaces), type, options)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
