import SwiftUI
import MapKit

// MARK: - Maps view

/// Native Apple Maps panel: geocode addresses, search for points of interest,
/// and open results in the Maps app. The top half renders a live MKMapView with
/// pins for the current results; the bottom half lists result details.
struct MapsView: View {
    @Environment(AppleMapsService.self) private var service
    @Environment(ThemeStore.self) private var theme

    @State private var query = ""
    @State private var results: [AppleMapsPOI] = []
    @State private var locations: [AppleMapsLocation] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchMode: SearchMode = .poi
    @State private var selectedResultID: UUID?
    @State private var showTraffic = true
    @State private var mapType: MapType = .standard
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    private enum SearchMode: String, CaseIterable, Identifiable {
        case poi = "Places"
        case geocode = "Address"
        var id: String { rawValue }
    }

    private enum MapType: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case satellite = "Satellite"
        case hybrid = "Hybrid"
        var id: String { rawValue }
        var mkType: MKMapType {
            switch self {
            case .standard: return .standard
            case .satellite: return .satellite
            case .hybrid: return .hybrid
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.secondaryBackground)

            Divider()

            searchBar
                .padding(8)
                .background(theme.secondaryBackground.opacity(0.5))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            if isSearching {
                ProgressView()
                    .padding()
            } else {
                mapSection
                Divider()
                resultsList
            }
        }
        .task {
            // Defer state changes so they don't happen during the view update.
            await Task.yield()
            service.requestAuthorization()
            // If the agent triggered a search before the view existed, run it now.
            if let requested = service.panelSearchQuery {
                query = requested
                if let modeRaw = service.panelSearchMode,
                   let mode = SearchMode(rawValue: modeRaw) {
                    searchMode = mode
                }
                await performSearch()
            }
        }
        .onChange(of: service.panelSearchTrigger) { _, _ in
            guard let requested = service.panelSearchQuery else { return }
            query = requested
            if let modeRaw = service.panelSearchMode,
               let mode = SearchMode(rawValue: modeRaw) {
                searchMode = mode
            }
            Task { await performSearch() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Maps")
                .font(.headline)
            Spacer()
            Picker("Map type", selection: $mapType) {
                Text("Map").tag(MapType.standard)
                Text("Sat").tag(MapType.satellite)
                Text("Hyb").tag(MapType.hybrid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            Toggle("Traffic", isOn: $showTraffic)
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Show Apple Maps traffic overlay")
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(searchMode == .poi ? "Search places" : "Geocode address", text: $query)
                .textFieldStyle(.plain)
            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }
            Picker("Search mode", selection: $searchMode) {
                ForEach(SearchMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            Button("Search") {
                Task { await performSearch() }
            }
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onSubmit {
            Task { await performSearch() }
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        ResultMap(
            region: $mapRegion,
            pois: searchMode == .poi ? results : [],
            locations: searchMode == .geocode ? locations : [],
            selectedID: $selectedResultID,
            showsTraffic: showTraffic,
            mapType: mapType.mkType
        )
        .frame(minHeight: 180, idealHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Results list

    private var resultsList: some View {
        Group {
            if searchMode == .geocode {
                List(locations) { location in
                    locationRow(location)
                }
            } else {
                List(results) { poi in
                    poiRow(poi)
                }
            }
        }
    }

    // MARK: - Rows

    private func locationRow(_ location: AppleMapsLocation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(location.name.isEmpty ? location.formattedAddress : location.name)
                .font(.headline)
            Text(location.formattedAddress)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(location.latitude, specifier: "%.5f"), \(location.longitude, specifier: "%.5f")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button("Open in Maps") {
                service.openInMaps(
                    query: location.name,
                    latitude: location.latitude,
                    longitude: location.longitude
                )
            }
        }
        .contextMenu {
            Button("Open in Maps") {
                service.openInMaps(
                    query: location.name,
                    latitude: location.latitude,
                    longitude: location.longitude
                )
            }
        }
    }

    private func poiRow(_ poi: AppleMapsPOI) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(poi.name)
                .font(.headline)
            if let address = poi.address, !address.isEmpty {
                Text(address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text("\(poi.latitude, specifier: "%.5f"), \(poi.longitude, specifier: "%.5f")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let phone = poi.phone, !phone.isEmpty {
                    Label(phone, systemImage: "phone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button("Open in Maps") {
                service.openInMaps(
                    query: poi.name,
                    latitude: poi.latitude,
                    longitude: poi.longitude
                )
            }
        }
        .contextMenu {
            Button("Open in Maps") {
                service.openInMaps(
                    query: poi.name,
                    latitude: poi.latitude,
                    longitude: poi.longitude
                )
            }
        }
    }

    // MARK: - Search

    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        results = []
        locations = []
        selectedResultID = nil
        defer { isSearching = false }

        do {
            switch searchMode {
            case .poi:
                let pois = try await service.searchNearby(query: trimmed)
                results = pois
                fitMapTo(pois: pois)
            case .geocode:
                let found = try await service.geocodeAddress(trimmed)
                locations = found
                fitMapTo(locations: found)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fitMapTo(pois: [AppleMapsPOI]) {
        guard !pois.isEmpty else { return }
        let coordinates = pois.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let region = coordinateRegion(for: coordinates)
        mapRegion = region
    }

    private func fitMapTo(locations: [AppleMapsLocation]) {
        guard !locations.isEmpty else { return }
        let coordinates = locations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let region = coordinateRegion(for: coordinates)
        mapRegion = region
    }

    private func coordinateRegion(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        let latitudes = coordinates.map { $0.latitude }
        let longitudes = coordinates.map { $0.longitude }
        let minLat = latitudes.min() ?? 0
        let maxLat = latitudes.max() ?? 0
        let minLon = longitudes.min() ?? 0
        let maxLon = longitudes.max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.01, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

// MARK: - Map representable

#if os(macOS)

/// `MKMapView` wrapper for SwiftUI on macOS, showing annotations for the
/// supplied POIs and geocoded locations.
struct ResultMap: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    let pois: [AppleMapsPOI]
    let locations: [AppleMapsLocation]
    @Binding var selectedID: UUID?
    let showsTraffic: Bool
    let mapType: MKMapType

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.isPitchEnabled = false
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        mapView.showsTraffic = showsTraffic
        mapView.mapType = mapType
        if !context.coordinator.isProgrammaticUpdate {
            mapView.setRegion(region, animated: true)
        }

        let currentAnnotations = mapView.annotations.compactMap { $0 as? ResultAnnotation }
        let targetAnnotations = annotations()

        let toRemove = currentAnnotations.filter { current in
            !targetAnnotations.contains { $0.id == current.id }
        }
        let toAdd = targetAnnotations.filter { target in
            !currentAnnotations.contains { $0.id == target.id }
        }

        mapView.removeAnnotations(toRemove)
        mapView.addAnnotations(toAdd)

        if let selectedID = selectedID,
           let annotation = targetAnnotations.first(where: { $0.id == selectedID }) {
            mapView.selectAnnotation(annotation, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func annotations() -> [ResultAnnotation] {
        var annotations: [ResultAnnotation] = []
        for poi in pois {
            annotations.append(ResultAnnotation(
                id: poi.id,
                title: poi.name,
                subtitle: poi.address,
                coordinate: CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
            ))
        }
        for location in locations {
            annotations.append(ResultAnnotation(
                id: location.id,
                title: location.name.isEmpty ? location.formattedAddress : location.name,
                subtitle: location.formattedAddress,
                coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
            ))
        }
        return annotations
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ResultMap
        var isProgrammaticUpdate = false

        init(_ parent: ResultMap) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let resultAnnotation = annotation as? ResultAnnotation else { return nil }
            let identifier = "resultPin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            if let markerView = view as? MKMarkerAnnotationView {
                markerView.markerTintColor = .systemBlue
                markerView.glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)
                markerView.canShowCallout = true
            }
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? ResultAnnotation else { return }
            parent.selectedID = annotation.id
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            isProgrammaticUpdate = true
            parent.region = mapView.region
            DispatchQueue.main.async {
                self.isProgrammaticUpdate = false
            }
        }
    }
}

final class ResultAnnotation: NSObject, MKAnnotation {
    let id: UUID
    let title: String?
    let subtitle: String?
    let coordinate: CLLocationCoordinate2D

    init(id: UUID, title: String?, subtitle: String?, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        super.init()
    }
}

#endif

// MARK: - Preview

#Preview {
    MapsView()
        .environment(AppleMapsService())
        .environment(ThemeStore())
}
