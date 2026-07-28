import SwiftUI

#if os(macOS)
struct TetheringView: View {
    @State private var service = TetheringService.shared

    var body: some View {
        HStack(spacing: 0) {
            sourceList
                .frame(minWidth: 180, maxWidth: 260)

            Divider()

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await service.discover()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if service.destination.folderURL == nil {
            ContentUnavailableView(
                "Set Capture Destination",
                systemImage: "folder.badge.plus",
                description: Text("Choose a folder before selecting a camera. Captures will be saved there.")
            )
            .overlay(alignment: .bottom) {
                Button("Select Destination…") {
                    selectDestination()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        } else if let selectedSourceID = service.selectedSourceID,
                  let source = service.availableSources.first(where: { $0.id == selectedSourceID }) {
            SourceDetailView(source: source)
                .id(source.id)
        } else {
            ContentUnavailableView(
                "No Camera Selected",
                systemImage: "camera",
                description: Text("Select or connect a capture source to begin tethering.")
            )
        }
    }

    private var sourceList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cameras")
                    .font(.headline)
                Spacer()
                Button(action: {
                    Task { await service.discover() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(service.isDiscovering)
                .labelStyle(.iconOnly)
                Button(action: selectDestination) {
                    Label("Destination", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .help("Choose the folder where captures are saved")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List(selection: $service.selectedSourceID) {
                if service.destination.folderURL == nil {
                    Section {
                        Button("Select Capture Folder…") {
                            selectDestination()
                        }
                        .padding(.vertical, 8)
                    } header: {
                        Text("Required")
                    }
                }

                Section("USB PTP Cameras") {
                    ForEach(Array(service.availableSources.filter { $0.type == .ptpUSB }.enumerated()), id: \.element.id) { _, source in
                        sourceRow(source)
                    }
                }
                .disabled(service.destination.folderURL == nil)

                Section("HDMI / Webcam") {
                    ForEach(Array(service.availableSources.filter { $0.type == .hdmiCapture || $0.type == .webcam }.enumerated()), id: \.element.id) { _, source in
                        sourceRow(source)
                    }
                }
                .disabled(service.destination.folderURL == nil)

                Section("Network / Future") {
                    ForEach(Array(service.availableSources.filter { $0.type == .ndi || $0.type == .djiWebcam }.enumerated()), id: \.element.id) { _, source in
                        sourceRow(source)
                    }
                }
                .disabled(service.destination.folderURL == nil)
            }
            .listStyle(.plain)
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let folder = service.destination.folderURL {
                        Label(folder.path, systemImage: "folder.fill")
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(.regularMaterial)
                            .cornerRadius(8)
                    }

                    if let error = service.discoveryError {
                        Text(error)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(8)
                            .background(.regularMaterial)
                            .cornerRadius(8)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func selectDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Capture Folder"
        panel.message = "Choose or create a folder where tethered captures will be saved."

        if panel.runModal() == .OK, let url = panel.url {
            service.destination.folderURL = url
        }
    }

    private func sourceRow(_ source: any CaptureSource) -> some View {
        Label(source.name, systemImage: icon(for: source.type))
            .tag(source.id)
    }

    private func icon(for type: CaptureSourceType) -> String {
        switch type {
        case .ptpUSB:      return "camera.fill"
        case .hdmiCapture: return "tv"
        case .webcam:      return "video.fill"
        case .ndi:         return "antenna.radiowaves.left.and.right"
        case .djiWebcam:   return "video.fill"
        }
    }
}

private struct SourceDetailView: View {
    let source: any CaptureSource
    @State private var session: CaptureSession?
    @State private var latestFrame: Data?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(source.name)
                    .font(.title2)
                Spacer()
                StatusBadge(status: source.status)
            }
            .padding()

            previewArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 8) {
                    controlBar
                        .padding()

                    recentCapturesBar
                        .frame(height: 90)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)

            if let error = session?.lastError {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            let session = TetheringService.shared.session(for: source)
            self.session = session
            await session.startPreview()
            previewTask = Task {
                // Listen to the session's source stream, because the session may have
                // been created with a different source instance than the one passed
                // to this view after a rediscovery.
                for await data in session.source.previewStream {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        latestFrame = data
                    }
                }
            }
        }
        .onDisappear {
            previewTask?.cancel()
            Task {
                await session?.stopPreview()
            }
        }
    }

    private var recentCapturesBar: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                ForEach(Array((session?.recentCaptures ?? []).enumerated()), id: \.element.id) { _, capture in
                    captureThumbnail(capture)
                }
            }
            .padding(.horizontal)
        }
        .background(Color.black.opacity(0.3))
    }

    private func captureThumbnail(_ capture: CapturedImage) -> some View {
        VStack {
            if let data = capture.thumbnailData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 60)
                    .cornerRadius(4)
            } else {
                Rectangle()
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 80, height: 60)
                    .cornerRadius(4)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            Text(capture.fileURL?.lastPathComponent ?? "capture")
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 80)
        }
        .help(capture.fileURL?.path ?? "")
    }

    private var previewArea: some View {
        ZStack {
            Color.black
            if let data = latestFrame, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ContentUnavailableView(
                    "No Preview",
                    systemImage: "video.slash",
                    description: Text("Start preview to see the live feed.")
                )
            }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button("Capture") {
                    Task { await session?.capture() }
                }
                .disabled(!source.supportsStillCapture)
                .keyboardShortcut(.return, modifiers: [.command])

                Spacer()

                Button("Destination…") {
                    selectDestination()
                }

                if let folder = TetheringService.shared.destination.folderURL {
                    Text(folder.path)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if source.isObsbotDevice {
                ObsbotPTZView()
            }
        }
    }

    private func selectDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Capture Folder"

        if panel.runModal() == .OK, let url = panel.url {
            TetheringService.shared.destination.folderURL = url
        }
    }
}

private struct StatusBadge: View {
    let status: CaptureSourceStatus

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .idle:       return .secondary
        case .connecting: return .orange
        case .previewing: return .green
        case .capturing:  return .blue
        case .error:      return .red
        }
    }

    private var text: String {
        switch status {
        case .idle:       return "Idle"
        case .connecting: return "Connecting"
        case .previewing: return "Previewing"
        case .capturing:  return "Capturing"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

extension CaptureSourceType: Hashable {}

#Preview {
    TetheringView()
}
#else
struct TetheringView: View {
    var body: some View {
        ContentUnavailableView(
            "Tethering Unavailable",
            systemImage: "camera",
            description: Text("Tethering is only supported on macOS.")
        )
    }
}
#endif
