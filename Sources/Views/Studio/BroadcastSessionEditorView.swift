import SwiftUI

struct BroadcastSessionEditorView: View {
    @State var session: BroadcastSession
    let onSave: (BroadcastSession) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPreset: BroadcastSession?

    var body: some View {
        NavigationStack {
            Form {
                Section("Preset") {
                    Picker("Platform", selection: $selectedPreset) {
                        Text("Custom").tag(nil as BroadcastSession?)
                        Divider()
                        ForEach(BroadcastSession.presets) { preset in
                            Text(preset.name).tag(preset as BroadcastSession?)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedPreset) { _, newValue in
                        guard let preset = newValue else { return }
                        session = BroadcastSession(
                            id: session.id,
                            name: preset.name,
                            inputURL: session.inputURL,
                            broadcastProtocol: preset.broadcastProtocol,
                            serverURL: preset.serverURL,
                            streamKey: session.streamKey,
                            isEnabled: session.isEnabled
                        )
                    }
                }

                TextField("Name", text: $session.name)
                    .textFieldStyle(.roundedBorder)

                Picker("Protocol", selection: $session.broadcastProtocol) {
                    ForEach(BroadcastProtocol.allCases) { proto in
                        Text(proto.rawValue).tag(proto)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Input URL", text: $session.inputURL)
                    .textFieldStyle(.roundedBorder)

                TextField("Server URL", text: $session.serverURL)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)

                TextField("Stream Key", text: $session.streamKey)
                    .textFieldStyle(.roundedBorder)

                Toggle("Enabled", isOn: $session.isEnabled)

                Section("Output URL") {
                    Text(session.outputURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle("Edit Broadcast")
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
        .frame(minWidth: 420, minHeight: 360)
    }
}

#Preview {
    BroadcastSessionEditorView(session: BroadcastSession.default()) { _ in }
}
