import SwiftUI
import MapKit
import UniformTypeIdentifiers

// MARK: - Story Game Map Section
//
// Map editor for Game Studio projects. Supports two workflows:
//   1. Static map image upload (user supplies any image, e.g. a screenshot
//      from Apple Maps or a hand-drawn map) with draggable location pins.
//   2. Live MapKit capture for real-world locations. Pan/zoom to the area,
//      tap Capture, and the current visible region is saved as the project's
//      static map image. Pins are then placed on that captured image.

struct StoryGameMapSection: View {
    @Binding var project: StoryGameProject
    let projectURL: URL?

    @State private var selectedLocationID: String?
    @State private var mode: MapMode = .staticMap
    @State private var isImportingMap = false
    @State private var captureError: String?
    @State private var camera: MapCameraPosition = .region(defaultRegion)
    @State private var draggedLocationID: String?
    @State private var dragStartPosition: MapPosition?

    private enum MapMode: Hashable {
        case staticMap
        case realMap
    }

    private var sortedLocations: [StoryLocation] {
        project.locations.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static var defaultRegion: MKCoordinateRegion {
        // Botany Bay, Sydney
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -33.95, longitude: 151.2),
            span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
        )
    }

    var body: some View {
        NavigationSplitView {
            locationList
        } detail: {
            detailContent
        }
        .alert("Import Map Image", isPresented: $isImportingMap) {
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Use the file picker to select a map image.")
        }
    }

    // MARK: - Sidebar

    private var locationList: some View {
        List(selection: $selectedLocationID) {
            ForEach(sortedLocations) { location in
                Label(location.name, systemImage: "mappin")
                    .tag(location.id)
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Locations")
        .toolbar {
            ToolbarItem {
                Button(action: addLocation) {
                    Image(systemName: "plus")
                }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            modeToolbar
            if let captureError {
                Text(captureError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }

            switch mode {
            case .staticMap:
                staticMapEditor
            case .realMap:
                realMapCapture
            }
        }
    }

    private var modeToolbar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                Text("Static Map").tag(MapMode.staticMap)
                Text("Real Map").tag(MapMode.realMap)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Spacer()

            if mode == .staticMap {
                Button("Import map image…") { importMapImage() }
                    .disabled(projectURL == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Static map editor

    private var staticMapEditor: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = mapImage {
                    mapImageView(image: image, container: geometry.size)
                } else {
                    emptyMapPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var emptyMapPlaceholder: some View {
        ContentUnavailableView(
            "No map image",
            systemImage: "map",
            description: Text("Import a map image, or switch to Real Map and capture the Botany Bay area.")
        )
    }

    private func mapImageView(image: NSImage, container: CGSize) -> some View {
        let frame = aspectFitFrame(
            contentSize: CGSize(width: image.size.width, height: image.size.height),
            containerSize: container
        )
        return ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)

            ForEach(sortedLocations) { location in
                if let position = location.mapPosition {
                    locationPin(location: location, position: position, imageFrame: frame)
                }
            }
        }
    }

    private var mapImage: NSImage? {
        guard let filename = project.mapImageFilename,
              let baseURL = projectURL else { return nil }
        let url = baseURL
            .appendingPathComponent("maps", isDirectory: true)
            .appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func locationPin(location: StoryLocation, position: MapPosition, imageFrame: CGRect) -> some View {
        let pinSize: CGFloat = 24
        let x = imageFrame.origin.x + position.x * imageFrame.width
        let y = imageFrame.origin.y + position.y * imageFrame.height
        let isSelected = selectedLocationID == location.id

        return ZStack {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.red : Color.orange)
            Image(systemName: "mappin.circle")
                .font(.title2)
                .foregroundStyle(.white)
        }
        .frame(width: pinSize, height: pinSize)
        .position(x: x, y: y)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if draggedLocationID == nil {
                        draggedLocationID = location.id
                        dragStartPosition = location.mapPosition
                    }
                    guard draggedLocationID == location.id,
                          let start = dragStartPosition else { return }
                    updateLocationPosition(
                        id: location.id,
                        start: start,
                        translation: value.translation,
                        imageFrame: imageFrame
                    )
                }
                .onEnded { _ in
                    draggedLocationID = nil
                    dragStartPosition = nil
                }
        )
        .onTapGesture {
            selectedLocationID = location.id
        }
        .help(location.name)
    }

    // MARK: - Real map capture

    private var realMapCapture: some View {
        MapReader { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .bottomTrailing) {
                    Map(position: $camera)
                        .mapStyle(.standard)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Button {
                        captureRealMap(proxy: proxy, frame: geometry.size)
                    } label: {
                        Label("Capture as map", systemImage: "camera")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(16)
                }
            }
        }
    }

    private func captureRealMap(proxy: MapProxy, frame: CGSize) {
        guard let projectURL else {
            captureError = "Save the project first before capturing a map."
            return
        }

        // Derive the visible coordinate region from the MapProxy.
        let localFrame = CGRect(origin: .zero, size: frame)
        let topLeft = CGPoint(x: localFrame.minX, y: localFrame.minY)
        let bottomRight = CGPoint(x: localFrame.maxX, y: localFrame.maxY)

        guard let nw = proxy.convert(topLeft, from: .local),
              let se = proxy.convert(bottomRight, from: .local) else {
            captureError = "Could not read map coordinates. Try again."
            return
        }

        let center = CLLocationCoordinate2D(
            latitude: (nw.latitude + se.latitude) / 2,
            longitude: (nw.longitude + se.longitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: abs(nw.latitude - se.latitude),
            longitudeDelta: abs(se.longitude - nw.longitude)
        )
        let region = MKCoordinateRegion(center: center, span: span)

        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: min(frame.width, 2048), height: min(frame.height, 2048))

        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start { snapshot, error in
            DispatchQueue.main.async {
                guard let snapshot else {
                    captureError = error?.localizedDescription ?? "Map capture failed."
                    return
                }
                saveCapturedMap(snapshot: snapshot, projectURL: projectURL)
            }
        }
    }

    private func saveCapturedMap(snapshot: MKMapSnapshotter.Snapshot, projectURL: URL) {
        let image = snapshot.image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            captureError = "Could not process captured map image."
            return
        }
        guard let pngData = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .png, properties: [:]) else {
            captureError = "Could not encode map image."
            return
        }

        do {
            let mapsDir = projectURL.appendingPathComponent("maps", isDirectory: true)
            try FileManager.default.createDirectory(
                at: mapsDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let destination = mapsDir.appendingPathComponent("map.png")
            try pngData.write(to: destination, options: .atomic)
            project.mapImageFilename = destination.lastPathComponent
            mode = .staticMap
            captureError = nil
        } catch {
            captureError = "Failed to save map: \(error.localizedDescription)"
        }
    }

    // MARK: - Position math

    private func updateLocationPosition(id: String, start: MapPosition, translation: CGSize, imageFrame: CGRect) {
        guard var location = project.locations[id] else { return }
        let dx = translation.width / imageFrame.width
        let dy = translation.height / imageFrame.height
        let next = MapPosition(
            x: max(0, min(1, start.x + dx)),
            y: max(0, min(1, start.y + dy))
        )
        location.mapPosition = next
        var locations = project.locations
        locations[id] = location
        project.locations = locations
    }

    private func aspectFitFrame(contentSize: CGSize, containerSize: CGSize) -> CGRect {
        let contentAspect = contentSize.width / max(contentSize.height, 1)
        let containerAspect = containerSize.width / max(containerSize.height, 1)
        let fitSize: CGSize
        if contentAspect > containerAspect {
            fitSize = CGSize(width: containerSize.width,
                             height: containerSize.width / contentAspect)
        } else {
            fitSize = CGSize(width: containerSize.height * contentAspect,
                             height: containerSize.height)
        }
        return CGRect(
            x: (containerSize.width - fitSize.width) / 2,
            y: (containerSize.height - fitSize.height) / 2,
            width: fitSize.width,
            height: fitSize.height
        )
    }

    // MARK: - Import

    private func importMapImage() {
        guard projectURL != nil else {
            captureError = "Save the project first to import a map image."
            return
        }
        captureError = nil

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Map Image"
        panel.message = "Select an image to use as the project map"
        panel.allowedContentTypes = [UTType.image]

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            copyImportedMap(from: url)
        }
    }

    private func copyImportedMap(from url: URL) {
        guard let projectURL else { return }
        do {
            let mapsDir = projectURL.appendingPathComponent("maps", isDirectory: true)
            try FileManager.default.createDirectory(
                at: mapsDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let filename = url.lastPathComponent
            let destination = mapsDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            project.mapImageFilename = filename
            mode = .staticMap
        } catch {
            captureError = "Failed to import map: \(error.localizedDescription)"
        }
    }

    // MARK: - Sidebar actions

    private func addLocation() {
        let base = "new_location"
        var id = base
        var counter = 1
        while project.locations[id] != nil {
            id = "\(base)_\(counter)"
            counter += 1
        }
        var locations = project.locations
        locations[id] = StoryLocation(
            id: id,
            name: "New Location",
            description: "",
            mapPosition: MapPosition(x: 0.5, y: 0.5),
            notes: ""
        )
        project.locations = locations
        selectedLocationID = id
    }

    private func delete(at offsets: IndexSet) {
        var locations = project.locations
        for offset in offsets {
            let location = sortedLocations[offset]
            locations.removeValue(forKey: location.id)
            if selectedLocationID == location.id {
                selectedLocationID = nil
            }
        }
        project.locations = locations
    }
}
