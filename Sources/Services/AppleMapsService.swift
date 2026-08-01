import Foundation
import MapKit
import AppKit
import Contacts

// MARK: - Apple Maps service

/// Bridges SwiftMaestro to Apple Maps and MapKit. Supports geocoding,
/// reverse-geocoding, points-of-interest search, and opening any of those
/// results directly in the Maps app.
///
/// MapKit geocoding and local search do not require an API key and run
/// in-process, so the agent can answer "where is X?" or "find coffee near Y"
/// without leaving the Mac.
@Observable
@MainActor
final class AppleMapsService {

    /// Shared instance used by both the SwiftUI environment and the tool
    /// handlers, so agent-driven panel search can be observed by the Maps view.
    static let shared = AppleMapsService()

    enum AuthorizationStatus: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var status: AuthorizationStatus = .notDetermined

    /// Agent-driven request to populate the in-app Maps panel search field.
    /// MapsView observes this and triggers a search when it changes.
    var panelSearchQuery: String?
    /// Agent-driven request to switch the in-app Maps panel search mode.
    /// MapsView observes this; valid values mirror `MapsView.SearchMode`.
    var panelSearchMode: String?
    /// Unique value changed each time the agent wants to force a fresh search
    /// (even if the query string itself is unchanged).
    var panelSearchTrigger: UUID?

    // MARK: - Authorization
    //
    // MapKit geocoding and local search do not prompt the user on macOS.
    // Network access is covered by the existing network.client entitlement.
    // We mark the service authorized on first use so the UI and tool handlers
    // can report a consistent state.

    func requestAuthorization() {
        status = .authorized
    }

    // MARK: - Geocoding

    /// Convert a free-form address or place name into coordinate candidates.
    func geocodeAddress(_ address: String) async throws -> [AppleMapsLocation] {
        let geocoder = CLGeocoder()
        let placemarks = try await geocoder.geocodeAddressString(address)
        return placemarks.map(AppleMapsLocation.init)
    }

    /// Convert coordinates into a human-readable address.
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> [AppleMapsLocation] {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let placemarks = try await geocoder.reverseGeocodeLocation(location)
        return placemarks.map(AppleMapsLocation.init)
    }

    // MARK: - Local search

    /// Search for points of interest matching a natural-language query.
    /// If `near` coordinates are provided, the search is biased to that region.
    func searchNearby(
        query: String,
        nearLatitude: Double? = nil,
        nearLongitude: Double? = nil,
        radius: Double = 10_000
    ) async throws -> [AppleMapsPOI] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest

        if let lat = nearLatitude, let lon = nearLongitude {
            let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: radius,
                longitudinalMeters: radius
            )
        }

        let search = MKLocalSearch(request: request)
        let response = try await search.start()
        return response.mapItems.map(AppleMapsPOI.init)
    }

    // MARK: - Open in Maps

    /// Open a location or query in the Maps app.
    /// Coordinates take precedence; otherwise a query/address is used.
    func openInMaps(
        query: String? = nil,
        address: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> Bool {
        if let lat = latitude, let lon = longitude {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let placemark = MKPlacemark(coordinate: coordinate)
            let mapItem = MKMapItem(placemark: placemark)
            if let query, !query.isEmpty {
                mapItem.name = query
            }
            return MKMapItem.openMaps(with: [mapItem], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
        }

        let searchTerm = (query?.isEmpty == false ? query : address)
        guard let term = searchTerm, !term.isEmpty else {
            // No query provided — just open Maps.
            return AppleMapsService.openApplication(bundleID: "com.apple.Maps")
        }

        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let urlString = "http://maps.apple.com/?q=\(encoded)"
        guard let url = URL(string: urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Shared helpers

    /// Open an application by bundle identifier, falling back to whatever
    /// `NSWorkspace` can find. Used when a URL scheme is not reliable.
    static func openApplication(bundleID: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
        return true
    }
}

// MARK: - Models

struct AppleMapsLocation: Sendable, Identifiable, Codable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let address: String?
    let city: String?
    let state: String?
    let country: String?

    init(from placemark: CLPlacemark) {
        self.id = UUID()
        self.name = placemark.name ?? ""
        self.latitude = placemark.location?.coordinate.latitude ?? 0
        self.longitude = placemark.location?.coordinate.longitude ?? 0
        self.address = placemark.postalAddress?.street
        self.city = placemark.postalAddress?.city
        self.state = placemark.postalAddress?.state
        self.country = placemark.postalAddress?.country
    }

    var formattedAddress: String {
        [address, city, state, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct AppleMapsPOI: Sendable, Identifiable, Codable {
    let id: UUID
    let name: String
    let latitude: Double
    let longitude: Double
    let address: String?
    let phone: String?
    let url: String?

    init(from mapItem: MKMapItem) {
        self.id = UUID()
        self.name = mapItem.name ?? ""
        self.latitude = mapItem.placemark.coordinate.latitude
        self.longitude = mapItem.placemark.coordinate.longitude
        self.address = mapItem.placemark.title
        self.phone = mapItem.phoneNumber
        self.url = mapItem.url?.absoluteString
    }
}
