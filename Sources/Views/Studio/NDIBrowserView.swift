import SwiftUI

struct NDIBrowserView: View {
    @StateObject private var service = NDIBrowserService.shared
    @State private var selectedSource: NDISource?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()

            Divider()

            if let error = service.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding()
            }

            List(service.sources) { source in
                sourceRow(source)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedSource = source
                    }
                    .contextMenu {
                        Button {
                            createMixerRoute(for: source)
                        } label: {
                            Label("Use as Mixer Source", systemImage: "arrow.triangle.merge")
                        }
                        Button {
                            copyEndpoint(source.endpoint)
                        } label: {
                            Label("Copy Endpoint", systemImage: "doc.on.doc")
                        }
                    }
            }
            .listStyle(.plain)

            if service.sources.isEmpty && !service.isScanning {
                ContentUnavailableView(
                    "No NDI Sources",
                    systemImage: "network.badge.shield.half.filled",
                    description: Text("Tap Scan to discover NDI sources on the local network. Click a discovered source to use it as a mixer input.")
                )
            }
        }
        .sheet(item: $selectedSource) { source in
            VStack(alignment: .leading, spacing: 16) {
                Text(source.name)
                    .font(.headline)
                Text(source.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack {
                    Button("Use as Mixer Source") {
                        createMixerRoute(for: source)
                        selectedSource = nil
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Copy Endpoint") {
                        copyEndpoint(source.endpoint)
                        selectedSource = nil
                    }

                    Spacer()

                    Button("Cancel") {
                        selectedSource = nil
                    }
                }
            }
            .padding()
            .frame(width: 420)
        }
    }

    private var header: some View {
        HStack {
            Text("NDI Browser")
                .font(.title2.bold())
            Spacer()
            if service.isScanning {
                ProgressView()
                    .controlSize(.small)
                Button("Stop") {
                    service.stopScan()
                }
            } else {
                Button("Scan") {
                    service.startScan()
                }
            }
        }
    }

    private func sourceRow(_ source: NDISource) -> some View {
        HStack {
            Image(systemName: "network.badge.shield.half.filled")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.headline)
                Text(source.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text("Available")
                .font(.caption)
                .foregroundStyle(.green)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func createMixerRoute(for source: NDISource) {
        let route = MixerRoute(
            id: UUID(),
            name: "NDI: \(source.name)",
            sourceURL: "ndi://\(source.endpoint)",
            destinationURL: "",
            isEnabled: false,
            transcode: false,
            videoBitrate: "2500k",
            audioBitrate: "128k"
        )
        StreamMixerService.shared.addRoute(route)
        StreamMixerService.shared.selectedRouteID = route.id
    }

    private func copyEndpoint(_ endpoint: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint, forType: .string)
#endif
    }
}

#Preview {
    NDIBrowserView()
}
