import SwiftUI
import AppKit

extension Notification.Name {
    static let reassignCameraLayer = Notification.Name("reassignCameraLayer")
}

/// Renders the actual content of a single scene layer.
struct SceneLayerPreviewView: View {
    let layer: SceneLayer
    let sceneSize: CGSize

    var body: some View {
        ZStack {
            switch layer.source {
            case .camera(let sourceID):
                CameraLayerPreview(sourceID: sourceID)
            case .ndi(let endpoint):
                NDILayerPreview(endpoint: endpoint)
            case .image(let urlString):
                ImageLayerPreview(urlString: urlString)
            case .text(let content, let fontSize, let foregroundColor, let backgroundColor):
                TextLayerPreview(
                    content: content,
                    fontSize: fontSize,
                    foregroundColor: foregroundColor,
                    backgroundColor: backgroundColor
                )
            case .color(let color):
                color.swiftUIColor
            case .screen:
                ScreenLayerPreview()
            }
        }
        .opacity(layer.isVisible ? layer.opacity : 0)
        .clipShape(Rectangle().path(in: cropRect))
        .clipped()
    }

    private var cropRect: CGRect {
        CGRect(
            x: layer.crop.x * layer.width,
            y: layer.crop.y * layer.height,
            width: layer.crop.width * layer.width,
            height: layer.crop.height * layer.height
        )
    }
}

// MARK: - Camera Layer Preview

private struct CameraLayerPreview: View {
    let sourceID: String
    @State private var service = TetheringService.shared
    @State private var latestFrame: Data?
    @State private var previewTask: Task<Void, Never>?
    @State private var isReassigning = false

    var body: some View {
        ZStack {
            Color.black
            if let data = latestFrame, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                    Text(sourceID.isEmpty ? "No Camera" : "Camera Not Found")
                        .font(.caption)
                    if sourceID.isEmpty || !cameraFound {
                        Button("Reassign Camera") {
                            isReassigning = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .task {
            await startPreview()
        }
        .onDisappear {
            previewTask?.cancel()
        }
        .onChange(of: sourceID) { _, _ in
            previewTask?.cancel()
            Task { await startPreview() }
        }
        .sheet(isPresented: $isReassigning) {
            ReassignCameraSheet(sourceID: sourceID)
        }
    }

    private var cameraFound: Bool {
        service.availableSources.contains(where: { $0.id.rawValue == sourceID })
    }

    private func startPreview() async {
        var source = service.availableSources.first(where: { $0.id.rawValue == sourceID })

        // If the source is not currently known, run discovery once and try again.
        if source == nil {
            await service.discover()
            source = service.availableSources.first(where: { $0.id.rawValue == sourceID })
        }

        guard let source else { return }
        let session = service.session(for: source)
        await session.startPreview()
        previewTask = Task {
            // Listen to the session's source stream, because the session may have
            // been created with a different source instance than the one we found.
            for await data in session.source.previewStream {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    latestFrame = data
                }
            }
        }
    }
}

// MARK: - Reassign Camera Sheet

private struct ReassignCameraSheet: View {
    let sourceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var service = TetheringService.shared
    @State private var selectedSourceID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reassign Camera")
                .font(.title3.bold())

            Picker("Camera", selection: $selectedSourceID) {
                ForEach(Array(service.availableSources.enumerated()), id: \.offset) { _, source in
                    Text(source.name).tag(source.id.rawValue)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Reassign") {
                    NotificationCenter.default.post(
                        name: .reassignCameraLayer,
                        object: nil,
                        userInfo: ["oldSourceID": sourceID, "newSourceID": selectedSourceID]
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedSourceID.isEmpty)
            }
        }
        .padding()
        .frame(width: 320)
        .task {
            await service.discover()
            if selectedSourceID.isEmpty, let first = service.availableSources.first {
                selectedSourceID = first.id.rawValue
            }
        }
    }
}

// MARK: - NDI Layer Preview

private struct NDILayerPreview: View {
    let endpoint: String

    var body: some View {
        ZStack {
            Color.black
            VStack {
                Image(systemName: "network.badge.shield.half.filled")
                Text("NDI: \(endpoint)")
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        }
    }
}

// MARK: - Image Layer Preview

private struct ImageLayerPreview: View {
    let urlString: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .allowsHitTesting(false)
            } else {
                VStack {
                    Image(systemName: "photo")
                    Text("Image")
                }
                .foregroundStyle(.white)
            }
        }
        .task {
            loadImage()
        }
        .onChange(of: urlString) { _, _ in
            loadImage()
        }
    }

    private func loadImage() {
        guard let url = URL(string: urlString), url.isFileURL else {
            image = nil
            return
        }
        image = NSImage(contentsOf: url)
    }
}

// MARK: - Text Layer Preview

private struct TextLayerPreview: View {
    let content: String
    let fontSize: Double
    let foregroundColor: SceneColor
    let backgroundColor: SceneColor?

    var body: some View {
        ZStack {
            if let backgroundColor {
                backgroundColor.swiftUIColor
            }
            Text(content)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(foregroundColor.swiftUIColor)
                .padding(8)
        }
    }
}

// MARK: - Screen Layer Preview

private struct ScreenLayerPreview: View {
    var body: some View {
        ZStack {
            Color.black
            VStack {
                Image(systemName: "display")
                Text("Screen Capture")
            }
            .foregroundStyle(.white)
        }
    }
}

#Preview {
    SceneLayerPreviewView(
        layer: SceneLayer(
            name: "Test",
            source: .text(content: "Hello", fontSize: 48, foregroundColor: .white, backgroundColor: .black)
        ),
        sceneSize: CGSize(width: 1920, height: 1080)
    )
    .frame(width: 320, height: 180)
}
