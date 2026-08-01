import SwiftUI

struct IngestSessionEditorView: View {
    @State var session: IngestSession
    let onSave: (IngestSession) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Protocol", selection: $session.streamProtocol) {
                    ForEach(IngestProtocol.allCases) { proto in
                        Text(proto.rawValue).tag(proto)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Port", value: $session.port, format: .number)
                    .textFieldStyle(.roundedBorder)

                if session.streamProtocol == .rtmp {
                    TextField("Path", text: $session.path)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Enabled", isOn: $session.isEnabled)
                Toggle("Auto-restart", isOn: $session.autoRestart)
                Toggle("Save to file", isOn: $session.saveToFile)

                if session.saveToFile {
                    TextField("Output directory", text: Binding(
                        get: { session.outputDirectory ?? "" },
                        set: { session.outputDirectory = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                Section("Input URL") {
                    Text(session.inputURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle("Edit Ingest Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(session)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

#Preview {
    IngestSessionEditorView(session: IngestSession.default(streamProtocol: .rtmp)) { _ in }
}
