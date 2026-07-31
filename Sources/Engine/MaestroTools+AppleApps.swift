import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Native Apple app tools: Maps, Photos, Stocks, News, Mail
//
// Exposes the additional native Apple apps the user asked for. Each service
// follows the same pattern as AppleNotesService / NumbersService: a
// `@MainActor` observable wrapper around the native framework or URL launcher.
//
// Capabilities:
//   - Maps: full MapKit geocoding, reverse-geocoding, POI search, open in Maps.
//   - Photos: PhotoKit album and asset metadata listing.
//   - Stocks: app launcher (no public API).
//   - News: app/URL launcher (no public API).
//   - Mail: launch Mail, compose drafts (JXA or mailto:), read the selected
//     message, and query OwnTrack open/click stats from the local relay.
extension MaestroTools {

    /// Each of these tools belongs to its own category so users can enable
    /// them individually per agent.
    static func registerAppleAppsTools() async {
        await ToolRegistry.shared.register([
            // MARK: Maps
            ToolDefinition(name: "geocode_address", spec: appleAppsToolSpecs[0], category: ToolCategory.maps.rawValue,
                handler: { call in await geocodeAddressTool(call) }),
            ToolDefinition(name: "reverse_geocode", spec: appleAppsToolSpecs[1], category: ToolCategory.maps.rawValue,
                handler: { call in await reverseGeocodeTool(call) }),
            ToolDefinition(name: "search_poi", spec: appleAppsToolSpecs[2], category: ToolCategory.maps.rawValue,
                handler: { call in await searchPOITool(call) }),
            ToolDefinition(name: "open_apple_maps", spec: appleAppsToolSpecs[3], category: ToolCategory.maps.rawValue,
                handler: { call in await openAppleMapsTool(call) }),
            ToolDefinition(name: "open_maps_panel", spec: appleAppsToolSpecs[9], category: ToolCategory.maps.rawValue,
                handler: { _ in await openMapsPanelTool() }),
            ToolDefinition(name: "search_maps_panel", spec: appleAppsToolSpecs[10], category: ToolCategory.maps.rawValue,
                handler: { call in await searchMapsPanelTool(call) }),

            // MARK: Photos
            ToolDefinition(name: "list_photos_albums", spec: appleAppsToolSpecs[4], category: ToolCategory.photos.rawValue,
                handler: { _ in await listPhotosAlbumsTool() }),
            ToolDefinition(name: "list_photos_assets", spec: appleAppsToolSpecs[5], category: ToolCategory.photos.rawValue,
                handler: { call in await listPhotosAssetsTool(call) }),
            ToolDefinition(name: "open_photos_app", spec: appleAppsToolSpecs[6], category: ToolCategory.photos.rawValue,
                handler: { _ in await openPhotosAppTool() }),

            // MARK: Stocks
            ToolDefinition(name: "open_stocks", spec: appleAppsToolSpecs[7], category: ToolCategory.stocks.rawValue,
                handler: { call in await openStocksTool(call) }),

            // MARK: News
            ToolDefinition(name: "open_apple_news", spec: appleAppsToolSpecs[8], category: ToolCategory.news.rawValue,
                handler: { call in await openAppleNewsTool(call) }),

            // MARK: Mail (Apple Mail.app — NOT MaestroMail, the standalone app)
            ToolDefinition(name: "open_apple_mail", spec: appleAppsToolSpecs[11], category: ToolCategory.mail.rawValue,
                handler: { _ in await openMailTool() }),
            ToolDefinition(name: "open_apple_mail_panel", spec: appleAppsToolSpecs[12], category: ToolCategory.mail.rawValue,
                handler: { _ in await openMailPanelTool() }),
            ToolDefinition(name: "compose_apple_mail", spec: appleAppsToolSpecs[13], category: ToolCategory.mail.rawValue,
                handler: { call in await composeMailTool(call) }),
            ToolDefinition(name: "apple_mail_selected_message", spec: appleAppsToolSpecs[14], category: ToolCategory.mail.rawValue,
                handler: { _ in await mailSelectedMessageTool() }),
            ToolDefinition(name: "apple_mail_tracking_summary", spec: appleAppsToolSpecs[15], category: ToolCategory.mail.rawValue,
                handler: { call in await mailTrackingSummaryTool(call) }),
        ])
    }

    static var appleAppsToolSpecs: [ToolSpec] {
        [
            // MARK: Maps
            rawSpec("geocode_address",
                "Geocode a free-form address or place name using Apple MapKit. Returns coordinates and formatted address.",
                properties: [
                    "address": ["type": "string", "description": "Address or place name, e.g. '1 Apple Park Way, Cupertino'."],
                ], required: ["address"]),
            rawSpec("reverse_geocode",
                "Convert latitude/longitude into a human-readable address using Apple MapKit.",
                properties: [
                    "latitude": ["type": "number", "description": "Latitude."],
                    "longitude": ["type": "number", "description": "Longitude."],
                ], required: ["latitude", "longitude"]),
            rawSpec("search_poi",
                "Search for points of interest near a location using Apple MapKit. Omit coordinates to search globally.",
                properties: [
                    "query": ["type": "string", "description": "Natural language query, e.g. 'coffee shop'."],
                    "near_latitude": ["type": "number", "description": "Optional latitude to bias search."],
                    "near_longitude": ["type": "number", "description": "Optional longitude to bias search."],
                    "radius": ["type": "number", "description": "Search radius in meters (default 10000)."],
                ], required: ["query"]),
            rawSpec("open_apple_maps",
                "Open Apple Maps to a query, address, or coordinate.",
                properties: [
                    "query": ["type": "string", "description": "Place name or search query."],
                    "address": ["type": "string", "description": "Full address."],
                    "latitude": ["type": "number", "description": "Latitude."],
                    "longitude": ["type": "number", "description": "Longitude."],
                ], required: []),
            rawSpec("open_maps_panel",
                "Open the SwiftMaestro in-app Maps panel. This is the embedded Maps panel, not the standalone Apple Maps app.",
                properties: [:], required: []),
            rawSpec("search_maps_panel",
                "Open the SwiftMaestro in-app Maps panel and search for a place or address inside it. The panel shows the map location and a traffic overlay if available, but it does NOT return real-time traffic conditions or incident data to the agent. Only describe what is actually returned by the tool.",
                properties: [
                    "query": ["type": "string", "description": "Place name or address to search for."],
                    "mode": ["type": "string", "description": "Search mode: 'Places' for POI search, 'Address' for address geocoding."],
                ], required: ["query"]),

            // MARK: Photos
            rawSpec("list_photos_albums",
                "List albums and smart albums in the macOS Photos library. Prompts for Photos access on first use.",
                properties: [:], required: []),
            rawSpec("list_photos_assets",
                "List recent photos/videos in the Photos library or a specific album.",
                properties: [
                    "album_id": ["type": "string", "description": "Album local identifier (from list_photos_albums). Omit for all photos."],
                    "limit": ["type": "integer", "description": "Max assets to return (default 25)."],
                ], required: []),
            rawSpec("open_photos_app",
                "Open the macOS Photos app.",
                properties: [:], required: []),

            // MARK: Stocks
            rawSpec("open_stocks",
                "Open the macOS Stocks app. Optionally tries to open a specific stock symbol.",
                properties: [
                    "symbol": ["type": "string", "description": "Optional stock symbol, e.g. 'AAPL'."],
                ], required: []),

            // MARK: News
            rawSpec("open_apple_news",
                "Open the Apple News app. Optionally open a specific Apple News URL or search term.",
                properties: [
                    "url": ["type": "string", "description": "Apple News URL (https://apple.news/...) or applenews:// URL."],
                    "search": ["type": "string", "description": "Search term to open in News."],
                ], required: []),

            // MARK: Mail (Apple Mail.app — NOT MaestroMail, the standalone app)
            rawSpec("open_apple_mail",
                "Open Apple's Mail.app (the macOS system email client). This is NOT MaestroMail, the standalone email app.",
                properties: [:], required: []),
            rawSpec("open_apple_mail_panel",
                "Open the SwiftMaestro in-app Mail panel (compose into Mail.app + OwnTrack tracking inspector for Mail.app messages).",
                properties: [:], required: []),
            rawSpec("compose_apple_mail",
                "Compose a new email draft in Apple's Mail.app. By default creates a visible draft inside Mail.app (requires Automation permission); set use_mail_app=false to open a mailto: URL in the user's default email client instead (which may not be Mail.app).",
                properties: [
                    "to": ["type": "string", "description": "Recipient address(es), comma separated."],
                    "cc": ["type": "string", "description": "Optional CC address(es), comma separated."],
                    "subject": ["type": "string", "description": "Subject line."],
                    "body": ["type": "string", "description": "Plain-text message body."],
                    "use_mail_app": ["type": "boolean", "description": "true (default) = draft in Mail.app via automation; false = mailto: in default client."],
                ], required: ["to"]),
            rawSpec("apple_mail_selected_message",
                "Read the message currently selected in Mail.app's front viewer: subject, sender, Message-ID, recipients. Requires Automation permission for Mail.",
                properties: [:], required: []),
            rawSpec("apple_mail_tracking_summary",
                "Fetch OwnTrack open/click/reply tracking stats for a message sent from Mail.app, from the embedded tracking relay. Pass a Message-ID, or omit it to use the message currently selected in Mail.app.",
                properties: [
                    "message_id": ["type": "string", "description": "RFC 822 Message-ID (angle brackets optional). Omit to use Mail.app's current selection."],
                ], required: []),
        ]
    }

    // MARK: - Shared service instances

    @MainActor
    private static let sharedMapsService = AppleMapsService.shared

    @MainActor
    private static let sharedPhotosService = ApplePhotosService()

    @MainActor
    private static let sharedStocksService = AppleStocksService()

    @MainActor
    private static let sharedNewsService = AppleNewsService()

    @MainActor
    private static let sharedMailService = AppleMailService.shared

    // MARK: - Maps argument types

    private struct GeocodeArgs: Codable { let address: String? }
    private struct ReverseGeocodeArgs: Codable { let latitude: Double?; let longitude: Double? }
    private struct SearchPOIArgs: Codable {
        let query: String?
        let near_latitude: Double?
        let near_longitude: Double?
        let radius: Double?
    }
    private struct OpenMapsArgs: Codable {
        let query: String?
        let address: String?
        let latitude: Double?
        let longitude: Double?
    }

    // MARK: - Maps implementations

    static func geocodeAddressTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: GeocodeArgs.self),
              let address = args.address?.trimmingCharacters(in: .whitespaces), !address.isEmpty else {
            return errorJSON("geocode_address requires 'address'")
        }
        await sharedMapsService.requestAuthorization()
        do {
            let results = try await sharedMapsService.geocodeAddress(address)
            guard !results.isEmpty else { return "No results found for '\(address)'." }
            return jsonString(["results": results.map(renderLocation)])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func reverseGeocodeTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReverseGeocodeArgs.self),
              let lat = args.latitude, let lon = args.longitude else {
            return errorJSON("reverse_geocode requires 'latitude' and 'longitude'")
        }
        await sharedMapsService.requestAuthorization()
        do {
            let results = try await sharedMapsService.reverseGeocode(latitude: lat, longitude: lon)
            guard !results.isEmpty else { return "No address found for those coordinates." }
            return jsonString(["results": results.map(renderLocation)])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func searchPOITool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SearchPOIArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return errorJSON("search_poi requires 'query'")
        }
        await sharedMapsService.requestAuthorization()
        do {
            let results = try await sharedMapsService.searchNearby(
                query: query,
                nearLatitude: args.near_latitude,
                nearLongitude: args.near_longitude,
                radius: args.radius ?? 10_000
            )
            guard !results.isEmpty else { return "No points of interest found for '\(query)'." }
            return jsonString(["results": results.map(renderPOI)])
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    static func openAppleMapsTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenMapsArgs.self)
        let ok = await sharedMapsService.openInMaps(
            query: args?.query,
            address: args?.address,
            latitude: args?.latitude,
            longitude: args?.longitude
        )
        return ok
            ? jsonString(["status": "opened", "destination": args?.query ?? args?.address ?? "current location"])
            : errorJSON("could not open Apple Maps")
    }

    private struct SearchMapsPanelArgs: Codable {
        let query: String?
        let mode: String?
    }

    /// Open the SwiftMaestro in-app Maps panel by updating the workspace layout
    /// and posting a notification so the main UI presents it.
    static func openMapsPanelTool() async -> String {
        return await MainActor.run(resultType: String.self) {
            let result = WorkspaceLayoutState.shared.open(.maps)
            NotificationCenter.default.post(name: .openWorkspacePanel, object: WorkspacePanelKind.maps)
            return jsonString(["status": "opened", "panel": "maps", "placement": String(describing: result)])
        }
    }

    /// Open the SwiftMaestro in-app Maps panel and drive its search field.
    /// Also performs the search and returns the results so the agent can describe
    /// what was actually found instead of hallucinating.
    static func searchMapsPanelTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: SearchMapsPanelArgs.self),
              let query = args.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return errorJSON("search_maps_panel requires 'query'")
        }
        await sharedMapsService.requestAuthorization()
        let mode = args.mode?.trimmingCharacters(in: .whitespaces)
        let searchMode = (mode?.isEmpty == false ? mode : "Places")

        let searchResult = await MainActor.run(resultType: String.self) {
            sharedMapsService.panelSearchQuery = query
            sharedMapsService.panelSearchMode = searchMode
            let result = WorkspaceLayoutState.shared.open(.maps)
            NotificationCenter.default.post(name: .openWorkspacePanel, object: WorkspacePanelKind.maps)
            return String(describing: result)
        }

        do {
            let found: [String: Any]
            if searchMode == "Address" {
                let locations = try await sharedMapsService.geocodeAddress(query)
                found = ["locations": locations.map(renderLocation)]
            } else {
                let pois = try await sharedMapsService.searchNearby(query: query)
                found = ["pois": pois.map(renderPOI)]
            }
            await MainActor.run {
                sharedMapsService.panelSearchTrigger = UUID()
            }
            return jsonString([
                "status": "searched",
                "panel": "maps",
                "query": query,
                "mode": searchMode,
                "placement": searchResult,
            ].merging(found) { current, _ in current })
        } catch {
            return errorJSON("panel search failed: \(error.localizedDescription)")
        }
    }

    private static func renderLocation(_ location: AppleMapsLocation) -> [String: Any] {
        [
            "name": location.name,
            "latitude": location.latitude,
            "longitude": location.longitude,
            "address": location.formattedAddress,
            "city": location.city,
            "state": location.state,
            "country": location.country,
        ]
    }

    private static func renderPOI(_ poi: AppleMapsPOI) -> [String: Any] {
        [
            "name": poi.name,
            "latitude": poi.latitude,
            "longitude": poi.longitude,
            "address": poi.address,
            "phone": poi.phone,
            "url": poi.url,
        ]
    }

    // MARK: - Photos argument types

    private struct ListPhotosAssetsArgs: Codable { let album_id: String?; let limit: Int? }

    // MARK: - Photos implementations

    static func listPhotosAlbumsTool() async -> String {
        await sharedPhotosService.requestAuthorization()
        await sharedPhotosService.refreshStatus()
        let albums = await sharedPhotosService.fetchAlbums()
        guard !albums.isEmpty else { return "No albums found (or access not yet granted)." }
        return jsonString(["albums": albums.map { album -> [String: Any] in
            [
                "id": album.id,
                "title": album.title,
                "type": album.type,
                "assetCount": album.assetCount,
            ]
        }])
    }

    static func listPhotosAssetsTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: ListPhotosAssetsArgs.self)
        await sharedPhotosService.requestAuthorization()
        await sharedPhotosService.refreshStatus()
        let assets = await sharedPhotosService.fetchAssets(
            inAlbumLocalIdentifier: args?.album_id,
            limit: args?.limit ?? 25
        )
        guard !assets.isEmpty else { return "No photos found." }
        return jsonString(["assets": assets.map { asset -> [String: Any] in
            var dict: [String: Any] = [
                "id": asset.id,
                "mediaType": asset.mediaType,
                "width": asset.pixelWidth,
                "height": asset.pixelHeight,
            ]
            if let creationDate = asset.creationDate { dict["creationDate"] = creationDate }
            if let modificationDate = asset.modificationDate { dict["modificationDate"] = modificationDate }
            if let latitude = asset.latitude { dict["latitude"] = latitude }
            if let longitude = asset.longitude { dict["longitude"] = longitude }
            if let filename = asset.filename { dict["filename"] = filename }
            return dict
        }])
    }

    static func openPhotosAppTool() async -> String {
        let ok = await sharedPhotosService.openPhotos()
        return ok ? jsonString(["status": "opened"]) : errorJSON("could not open Photos")
    }

    // MARK: - Stocks argument types

    private struct OpenStocksArgs: Codable { let symbol: String? }

    // MARK: - Stocks implementations

    static func openStocksTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenStocksArgs.self)
        let ok = await sharedStocksService.openStocks(symbol: args?.symbol)
        return ok
            ? jsonString(["status": "opened", "symbol": args?.symbol ?? "none"])
            : errorJSON("could not open Stocks")
    }

    // MARK: - News argument types

    private struct OpenNewsArgs: Codable { let url: String?; let search: String? }

    // MARK: - News implementations

    static func openAppleNewsTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenNewsArgs.self)
        let ok = await sharedNewsService.openNews(url: args?.url, search: args?.search)
        return ok
            ? jsonString(["status": "opened", "url": args?.url, "search": args?.search])
            : errorJSON("could not open Apple News")
    }

    // MARK: - Mail argument types

    /// Bool decoder that also accepts "true"/"false" strings and 0/1 — models
    /// don't always emit strict JSON booleans for boolean parameters.
    private struct FlexibleBool: Codable {
        let value: Bool
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let string = try? container.decode(String.self) {
                value = (string as NSString).boolValue
            } else if let int = try? container.decode(Int.self) {
                value = int != 0
            } else {
                throw DecodingError.typeMismatch(
                    Bool.self,
                    DecodingError.Context(codingPath: decoder.codingPath,
                                          debugDescription: "Expected Bool, String, or Int"))
            }
        }
    }

    private struct ComposeMailArgs: Codable {
        let to: String?
        let cc: String?
        let subject: String?
        let body: String?
        let use_mail_app: FlexibleBool?
    }
    private struct MailTrackingArgs: Codable { let message_id: String? }

    // MARK: - Mail implementations

    static func openMailTool() async -> String {
        let ok = await sharedMailService.openMail()
        return ok ? jsonString(["status": "opened"]) : errorJSON("could not open Mail")
    }

    /// Open the SwiftMaestro in-app Mail panel by updating the workspace layout
    /// and posting a notification so the main UI presents it.
    static func openMailPanelTool() async -> String {
        return await MainActor.run(resultType: String.self) {
            let result = WorkspaceLayoutState.shared.open(.mail)
            NotificationCenter.default.post(name: .openWorkspacePanel, object: WorkspacePanelKind.mail)
            return jsonString(["status": "opened", "panel": "mail", "placement": String(describing: result)])
        }
    }

    static func composeMailTool(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ComposeMailArgs.self),
              let to = args.to?.trimmingCharacters(in: .whitespaces), !to.isEmpty else {
            return errorJSON("compose_apple_mail requires 'to'")
        }
        let subject = args.subject ?? ""
        let body = args.body ?? ""
        let cc = args.cc ?? ""
        let useMailApp = args.use_mail_app?.value ?? true

        if useMailApp {
            func splitAddresses(_ raw: String) -> [String] {
                raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            do {
                let draftID = try await sharedMailService.composeInMailApp(
                    to: splitAddresses(to),
                    cc: splitAddresses(cc),
                    subject: subject,
                    content: body
                )
                return jsonString(["status": "draft_created", "client": "Mail.app", "draftID": draftID])
            } catch {
                return errorJSON("Mail.app compose failed: \(error.localizedDescription)")
            }
        } else {
            let ok = await sharedMailService.compose(to: to, cc: cc, subject: subject, body: body)
            return ok
                ? jsonString(["status": "handed_off", "client": "default email client (mailto:)"])
                : errorJSON("could not open mailto: URL")
        }
    }

    static func mailSelectedMessageTool() async -> String {
        do {
            guard let message = try await sharedMailService.selectedMessage() else {
                return "No message selected in Mail (or Mail has no viewer open)."
            }
            var dict: [String: Any] = [:]
            if let messageID = message.messageID {
                dict["messageID"] = messageID
                dict["normalizedMessageID"] = AppleMailService.normalizeMessageID(messageID)
            }
            if let subject = message.subject { dict["subject"] = subject }
            if let sender = message.sender { dict["sender"] = sender }
            if let dateSent = message.dateSent { dict["dateSent"] = dateSent }
            dict["toRecipients"] = message.toRecipients
            return jsonString(dict)
        } catch {
            return errorJSON("could not read Mail's selection: \(error.localizedDescription)")
        }
    }

    static func mailTrackingSummaryTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: MailTrackingArgs.self)
        var messageID = args?.message_id?.trimmingCharacters(in: .whitespaces)

        if messageID?.isEmpty != false {
            // Fall back to Mail's current selection.
            do {
                messageID = try await sharedMailService.selectedMessage()?.messageID
            } catch {
                return errorJSON("no message_id given and Mail selection unreadable: \(error.localizedDescription)")
            }
        }
        guard let rawID = messageID, !rawID.isEmpty else {
            return errorJSON("apple_mail_tracking_summary needs 'message_id' or a selected message in Mail.app")
        }
        let normalized = AppleMailService.normalizeMessageID(rawID)

        guard await sharedMailService.ensureRelayRunning() else {
            return errorJSON("No OwnTrack relay reachable at \(await sharedMailService.relayBaseURLString) and the embedded relay failed to start")
        }

        do {
            async let summaryFetch = sharedMailService.trackingSummary(messageID: normalized)
            async let eventsFetch = sharedMailService.trackingEvents(messageID: normalized)
            let summary = try await summaryFetch
            let events = try await eventsFetch

            // Built piecemeal — a single large dictionary literal trips the
            // type-checker's expression-time limit.
            let recentEvents: [[String: Any]] = events
                .sorted(by: { $0.timestamp > $1.timestamp })
                .prefix(10)
                .map { event in
                    var dict: [String: Any] = [
                        "type": event.type.rawValue,
                        "timestamp": event.timestamp.timeIntervalSince1970,
                    ]
                    if let recipient = event.recipient { dict["recipient"] = recipient }
                    if let quality = event.attributes["openQuality"] { dict["openQuality"] = quality }
                    return dict
                }

            var result: [String: Any] = [
                "messageID": summary.messageID,
                "subject": summary.subject ?? "",
                "recipients": summary.recipients,
                "sent": summary.sentCount,
                "opens": summary.openCount,
                "clicks": summary.clickCount,
                "replies": summary.replyCount,
                "uniqueOpenRecipients": summary.uniqueOpenRecipients,
                "uniqueClickRecipients": summary.uniqueClickRecipients,
                "openQuality": summary.openQualityCounts,
                "recentEvents": recentEvents,
            ]
            if let firstOpened = summary.firstOpenedAt { result["firstOpenedAt"] = firstOpened.timeIntervalSince1970 }
            if let lastOpened = summary.lastOpenedAt { result["lastOpenedAt"] = lastOpened.timeIntervalSince1970 }
            if let firstClicked = summary.firstClickedAt { result["firstClickedAt"] = firstClicked.timeIntervalSince1970 }
            if let firstReplied = summary.firstRepliedAt { result["firstRepliedAt"] = firstReplied.timeIntervalSince1970 }
            return jsonString(result)
        } catch {
            return errorJSON("tracking lookup failed for \(normalized): \(error.localizedDescription)")
        }
    }
}
