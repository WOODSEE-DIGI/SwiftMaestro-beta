import SwiftUI

struct MixerRouteEditorView: View {
    @State var route: MixerRoute
    let onSave: (MixerRoute) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $route.name)
                    .textFieldStyle(.roundedBorder)

                TextField("Source URL", text: $route.sourceURL)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)

                TextField("Destination URL", text: $route.destinationURL)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)

                Toggle("Enabled", isOn: $route.isEnabled)
                Toggle("Transcode", isOn: $route.transcode)

                if route.transcode {
                    TextField("Video bitrate", text: $route.videoBitrate)
                        .textFieldStyle(.roundedBorder)
                    TextField("Audio bitrate", text: $route.audioBitrate)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle("Edit Route")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(route)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

#Preview {
    MixerRouteEditorView(route: MixerRoute.default()) { _ in }
}
