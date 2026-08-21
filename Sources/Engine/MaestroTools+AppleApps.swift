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
//     message.
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

            // MARK: Stocks panel tools
            ToolDefinition(name: "list_stocks", spec: appleAppsToolSpecs[15], category: ToolCategory.stocks.rawValue,
                handler: { _ in await listStocksTool() }),
            ToolDefinition(name: "add_stock", spec: appleAppsToolSpecs[16], category: ToolCategory.stocks.rawValue,
                handler: { call in await addStockTool(call) }),
            ToolDefinition(name: "remove_stock", spec: appleAppsToolSpecs[17], category: ToolCategory.stocks.rawValue,
                handler: { call in await removeStockTool(call) }),
            ToolDefinition(name: "stock_quote", spec: appleAppsToolSpecs[18], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockQuoteTool(call) }),
            ToolDefinition(name: "stock_report", spec: appleAppsToolSpecs[19], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockReportTool(call) }),
            ToolDefinition(name: "stock_alert", spec: appleAppsToolSpecs[20], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockAlertTool(call) }),

            // MARK: Stocks investigation tools (SEC EDGAR + Yahoo)
            ToolDefinition(name: "stock_holders", spec: appleAppsToolSpecs[21], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockHoldersTool(call) }),
            ToolDefinition(name: "stock_insider_transactions", spec: appleAppsToolSpecs[22], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockInsiderTool(call) }),
            ToolDefinition(name: "stock_proxy_filings", spec: appleAppsToolSpecs[23], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockProxyTool(call) }),
            ToolDefinition(name: "stock_investigate", spec: appleAppsToolSpecs[24], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockInvestigateTool(call) }),
            ToolDefinition(name: "stock_note", spec: appleAppsToolSpecs[25], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockNoteTool(call) }),
            ToolDefinition(name: "stock_flag", spec: appleAppsToolSpecs[26], category: ToolCategory.stocks.rawValue,
                handler: { call in await stockFlagTool(call) }),
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
                "Open the SwiftMaestro in-app Mail panel (compose into Mail.app).",
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

            // MARK: Stocks panel tools (watchlist + quotes via Yahoo Finance — no API key)
            rawSpec("list_stocks",
                "List the Stocks panel watchlist with the latest cached quote for each symbol (price, intraday change, day range).",
                properties: [:], required: []),
            rawSpec("add_stock",
                "Add a symbol to the Stocks panel watchlist and fetch its quote. Symbols: US tickers plain ('AAPL'), other markets with suffix ('bhp.au'), indices with caret ('^spx').",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol, e.g. 'AAPL'."],
                ], required: ["symbol"]),
            rawSpec("remove_stock",
                "Remove a symbol from the Stocks panel watchlist.",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol to remove."],
                ], required: ["symbol"]),
            rawSpec("stock_quote",
                "Fetch a fresh quote for any symbol (does not add it to the watchlist). Returns price, day open/high/low, volume, and intraday change.",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol, e.g. 'AAPL' or '^spx'."],
                ], required: ["symbol"]),
            // MARK: Stocks report + alerts
            rawSpec("stock_report",
                "Generate a stock report from the watchlist or custom symbols. Outputs as xlsx spreadsheet, csv, or markdown table. Saves to the specified path or ~/Desktop by default.",
                properties: [
                    "format": ["type": "string", "description": "Output format: 'xlsx' (default), 'csv', or 'md'."],
                    "symbols": ["type": "string", "description": "Comma-separated symbols to include (defaults to full watchlist). E.g. 'AAPL,MSFT,BHP.AX'."],
                    "path": ["type": "string", "description": "Absolute path to save the report. Defaults to ~/Desktop/stocks-report-YYYY-MM-DD.ext"],
                ], required: []),
            rawSpec("stock_alert",
                "Set, list, or check price alerts for stock symbols. When checked, returns any breaches where the current price crossed your threshold.",
                properties: [
                    "action": ["type": "string", "description": "'add' to create an alert, 'list' to show active alerts, 'remove' to delete one, 'check' to evaluate all alerts against live prices."],
                    "symbol": ["type": "string", "description": "Ticker symbol (required for add/remove)."],
                    "condition": ["type": "string", "description": "Trigger condition: 'above' or 'below' (required for add)."],
                    "threshold": ["type": "number", "description": "Price threshold (required for add)."],
                    "message": ["type": "string", "description": "Optional note for the alert."],
                ], required: ["action"]),

            // MARK: Stocks investigation tools (SEC EDGAR + Yahoo Finance)
            rawSpec("stock_holders",
                "Fetch institutional holders for a stock: top shareholders, shares held, percent ownership, and quarter-over-quarter changes. Data from Yahoo Finance. Use when investigating who owns a company or tracking activist positions.",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol, e.g. 'AAPL'."],
                ], required: ["symbol"]),
            rawSpec("stock_insider_transactions",
                "Fetch insider transactions (SEC Form 4) for a stock: buys, sells, option exercises by executives and directors. Data from SEC EDGAR. Use for insider trading analysis or monitoring executive behavior.",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol, e.g. 'AAPL'. US-listed companies only."],
                    "limit": ["type": "number", "description": "Max transactions to return (default 30)."],
                ], required: ["symbol"]),
            rawSpec("stock_proxy_filings",
                "Fetch proxy/voting filings (DEF 14A) for a stock: shareholder meeting proposals, board members, executive compensation, meeting dates. Data from SEC EDGAR. Use for governance analysis, ESG research, or understanding shareholder votes.",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol, e.g. 'AAPL'. US-listed companies only."],
                ], required: ["symbol"]),
            rawSpec("stock_investigate",
                "Full investigation sweep on a stock: fetches quote, institutional holders, insider transactions, and proxy filings in one call. Adds the symbol to the watchlist if not already tracked. Returns a consolidated summary.",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol to investigate, e.g. 'AAPL'."],
                ], required: ["symbol"]),
            rawSpec("stock_note",
                "Add an investigation note to a stock. Notes persist in the database and are shown in the Stocks panel Notes tab.",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol."],
                    "note": ["type": "string", "description": "Note content — observations, thesis, findings."],
                ], required: ["symbol", "note"]),
            rawSpec("stock_flag",
                "Flag or unflag a stock as suspicious. Flagged stocks show an orange flag in the Stocks panel. Use to mark stocks under suspicion for fraud, insider trading patterns, or other concerns.",
                properties: [
                    "symbol": ["type": "string", "description": "Ticker symbol."],
                    "action": ["type": "string", "description": "'flag' or 'unflag' (default 'flag')."],
                    "reason": ["type": "string", "description": "Reason for flagging (default 'Manual flag')."],
                ], required: ["symbol"]),
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
                "mode": searchMode ?? "unknown",
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
            "city": location.city ?? "",
            "state": location.state ?? "",
            "country": location.country ?? "",
        ]
    }

    private static func renderPOI(_ poi: AppleMapsPOI) -> [String: Any] {
        [
            "name": poi.name,
            "latitude": poi.latitude,
            "longitude": poi.longitude,
            "address": poi.address ?? "",
            "phone": poi.phone ?? "",
            "url": poi.url ?? "",
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

    // MARK: - Stocks panel implementations (watchlist + quotes via Yahoo Finance)

    @MainActor
    static func listStocksTool() async -> String {
        let store = StocksStore.shared
        if store.quotes.isEmpty { await store.refreshQuotes() }
        let items: [[String: Any]] = store.watchlist.map { item in
            let quote = store.quotes[item.symbol]
            return [
                "symbol": item.displaySymbol,
                "price": quote?.price as Any,
                "change_percent": quote?.changePercent as Any,
                "day_low": quote?.dayLow as Any,
                "day_high": quote?.dayHigh as Any,
                "previous_close": quote?.previousClose as Any,
            ]
        }
        return jsonString(["watchlist": items, "count": items.count])
    }

    @MainActor
    static func addStockTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenStocksArgs.self)
        guard let symbol = args?.symbol, !symbol.isEmpty else { return errorJSON("'symbol' is required") }
        guard let item = StocksStore.shared.add(symbol: symbol) else {
            return errorJSON("invalid symbol '\(symbol)'")
        }
        return jsonString(["status": "added", "symbol": item.displaySymbol, "watchlist_count": StocksStore.shared.watchlist.count])
    }

    @MainActor
    static func removeStockTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenStocksArgs.self)
        guard let symbol = args?.symbol, !symbol.isEmpty else { return errorJSON("'symbol' is required") }
        StocksStore.shared.remove(symbol: symbol)
        return jsonString(["status": "removed", "symbol": symbol.uppercased()])
    }

    @MainActor
    static func stockQuoteTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenStocksArgs.self)
        guard let symbol = args?.symbol, !symbol.isEmpty else { return errorJSON("'symbol' is required") }
        guard let quote = await StocksStore.shared.quote(for: symbol) else {
            return errorJSON("no quote for '\(symbol)' — check the ticker (US: 'AAPL', other markets: 'BHP.AX', indices: '^GSPC')")
        }
        return jsonString([
            "symbol": quote.symbol,
            "price": quote.price,
            "previous_close": quote.previousClose as Any,
            "day_high": quote.dayHigh as Any,
            "day_low": quote.dayLow as Any,
            "volume": quote.volume as Any,
            "change_percent": quote.changePercent as Any,
        ])
    }

    // MARK: - Stock report

    private struct StockReportArgs: Codable {
        let format: String?
        let symbols: String?
        let path: String?
    }

    @MainActor
    static func stockReportTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: StockReportArgs.self)
        let fmt = (args?.format ?? "xlsx").lowercased()
        guard ["xlsx", "csv", "md"].contains(fmt) else {
            return errorJSON("format must be 'xlsx', 'csv', or 'md' (got '\(fmt)')")
        }

        // Resolve symbols: custom list or full watchlist.
        let store = StocksStore.shared
        let items: [StockWatchItem]
        if let raw = args?.symbols, !raw.isEmpty {
            let symbols = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            items = symbols.compactMap { store.add(symbol: $0) }
        } else {
            items = store.watchlist
            if items.isEmpty { return errorJSON("watchlist is empty — add symbols first or pass 'symbols'") }
        }

        // Fetch fresh quotes for all symbols.
        for item in items {
            if store.quotes[item.symbol] == nil {
                _ = await store.quote(for: item.symbol)
            }
        }

        // Build rows.
        var rows: [[String]] = [["Symbol", "Price", "Change %", "Day Low", "Day High", "Prev Close", "Volume"]]
        for item in items {
            let q = store.quotes[item.symbol]
            let price = q.map { String(format: "%.2f", $0.price) } ?? "—"
            let change: String = {
                guard let pct = q?.changePercent else { return "—" }
                return String(format: "%+.2f%%", pct)
            }()
            let dayLow: String = {
                guard let v = q?.dayLow else { return "—" }
                return String(format: "%.2f", v)
            }()
            let dayHigh: String = {
                guard let v = q?.dayHigh else { return "—" }
                return String(format: "%.2f", v)
            }()
            let prevClose: String = {
                guard let v = q?.previousClose else { return "—" }
                return String(format: "%.2f", v)
            }()
            let volume: String = {
                guard let v = q?.volume else { return "—" }
                return formatVolume(v)
            }()
            rows.append([item.displaySymbol, price, change, dayLow, dayHigh, prevClose, volume])
        }

        // Resolve output path.
        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())
        let fileName = "stocks-report-\(dateStr).\(fmt)"
        let outURL: URL
        if let raw = args?.path, !raw.isEmpty, raw.hasPrefix("/") {
            outURL = URL(fileURLWithPath: raw)
        } else {
            outURL = desktop.appendingPathComponent(fileName)
        }

        // Write file.
        do {
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes: Int
            switch fmt {
            case "csv":
                let csv = rows.map { $0.joined(separator: ",") }.joined(separator: "\n")
                try csv.write(to: outURL, atomically: true, encoding: .utf8)
                bytes = csv.utf8.count
            case "md":
                var md = "# Stock Report — \(dateStr)\n\n"
                // Markdown table
                for (i, row) in rows.enumerated() {
                    md += "| " + row.joined(separator: " | ") + " |\n"
                    if i == 0 {
                        md += "| " + row.map { _ in "---" }.joined(separator: " | ") + " |\n"
                    }
                }
                try md.write(to: outURL, atomically: true, encoding: .utf8)
                bytes = md.utf8.count
            default: // xlsx
                bytes = try DocEngine.createXLSX(outURL, rows: rows, sheetName: "Stock Report")
            }
            return jsonString([
                "status": "created", "format": fmt,
                "path": outURL.path, "bytes": "\(bytes)",
                "symbols": items.map(\.displaySymbol),
                "count": items.count,
            ])
        } catch {
            return errorJSON("failed to create report: \(error.localizedDescription)")
        }
    }

    private static func formatVolume(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return "\(Int(v))"
    }

    // MARK: - Stock alerts

    private struct StockAlertArgs: Codable {
        let action: String?
        let symbol: String?
        let condition: String?
        let threshold: Double?
        let message: String?
    }

    private struct PriceAlert: Codable, Identifiable, Sendable {
        var id: String { "\(symbol)-\(condition)-\(threshold)" }
        let symbol: String
        let condition: String   // "above" or "below"
        let threshold: Double
        let message: String
        let createdAt: Date
    }

    private static var alertsURL: URL {
        SwiftMaestroPaths.appSupportDir.appendingPathComponent("stock-alerts.json")
    }

    private static func loadAlerts() -> [PriceAlert] {
        guard let data = try? Data(contentsOf: alertsURL),
              let alerts = try? JSONDecoder().decode([PriceAlert].self, from: data) else { return [] }
        return alerts
    }

    private static func saveAlerts(_ alerts: [PriceAlert]) {
        guard let data = try? JSONEncoder().encode(alerts) else { return }
        try? data.write(to: alertsURL, options: .atomic)
    }

    @MainActor
    static func stockAlertTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: StockAlertArgs.self)
        guard let action = args?.action?.lowercased() else {
            return errorJSON("'action' is required: add, list, remove, check")
        }

        switch action {
        case "add":
            guard let symbol = args?.symbol?.uppercased(), !symbol.isEmpty else {
                return errorJSON("'symbol' is required for add")
            }
            guard let condition = args?.condition?.lowercased(),
                  ["above", "below"].contains(condition) else {
                return errorJSON("'condition' must be 'above' or 'below'")
            }
            guard let threshold = args?.threshold else {
                return errorJSON("'threshold' price is required for add")
            }
            let alert = PriceAlert(
                symbol: symbol, condition: condition, threshold: threshold,
                message: args?.message ?? "",
                createdAt: Date())
            var alerts = loadAlerts()
            alerts.append(alert)
            saveAlerts(alerts)
            return jsonString([
                "status": "alert_created",
                "symbol": symbol, "condition": condition,
                "threshold": threshold, "message": alert.message,
            ])

        case "list":
            let alerts = loadAlerts()
            let items: [[String: Any]] = alerts.map { a in
                ["symbol": a.symbol, "condition": a.condition,
                 "threshold": a.threshold, "message": a.message]
            }
            return jsonString(["alerts": items, "count": items.count])

        case "remove":
            guard let symbol = args?.symbol?.uppercased(), !symbol.isEmpty else {
                return errorJSON("'symbol' is required for remove")
            }
            var alerts = loadAlerts()
            let before = alerts.count
            alerts.removeAll { $0.symbol == symbol }
            guard alerts.count < before else {
                return errorJSON("no alert found for '\(symbol)'")
            }
            saveAlerts(alerts)
            return jsonString(["status": "removed", "symbol": symbol, "remaining": alerts.count])

        case "check":
            let alerts = loadAlerts()
            guard !alerts.isEmpty else {
                return jsonString(["status": "no_alerts", "breaches": []])
            }
            // Fetch live quotes for all alerted symbols.
            let uniqueSymbols = Set(alerts.map(\.symbol))
            var quotes: [String: StockQuote] = [:]
            for sym in uniqueSymbols {
                if let q = await StocksStore.shared.quote(for: sym) {
                    quotes[sym] = q
                }
            }
            // Evaluate breaches.
            var breaches: [[String: Any]] = []
            for alert in alerts {
                guard let q = quotes[alert.symbol] else { continue }
                let breached: Bool
                switch alert.condition {
                case "above": breached = q.price >= alert.threshold
                case "below": breached = q.price <= alert.threshold
                default: breached = false
                }
                if breached {
                    breaches.append([
                        "symbol": alert.symbol,
                        "condition": alert.condition,
                        "threshold": alert.threshold,
                        "current_price": q.price,
                        "message": alert.message,
                        "change_percent": q.changePercent as Any,
                    ])
                }
            }
            // Log breaches to file.
            if !breaches.isEmpty {
                let logURL = SwiftMaestroPaths.appSupportDir.appendingPathComponent("stock-alert-log.txt")
                let ts = ISO8601DateFormatter().string(from: Date())
                var log = ""
                for b in breaches {
                    log += "[\(ts)] \(b["symbol"] ?? "?") \(b["condition"] ?? "?") \(b["threshold"] ?? 0) → current \(b["current_price"] ?? 0) (\(b["message"] ?? ""))\n"
                }
                if let data = log.data(using: .utf8),
                   let fh = FileHandle(forWritingAtPath: logURL.path) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                } else {
                    try? log.write(to: logURL, atomically: true, encoding: .utf8)
                }
            }
            return jsonString([
                "status": "checked",
                "total_alerts": alerts.count,
                "breaches": breaches,
                "breach_count": breaches.count,
            ])

        default:
            return errorJSON("unknown action '\(action)' — use add, list, remove, or check")
        }
    }

    // MARK: - Stocks Investigation Tools

    private struct StockSymbolArgs: Codable { let symbol: String? }
    private struct StockInsiderArgs: Codable { let symbol: String?; let limit: Double? }
    private struct StockNoteArgs: Codable { let symbol: String?; let note: String? }
    private struct StockFlagArgs: Codable { let symbol: String?; let action: String?; let reason: String? }

    @MainActor
    static func stockHoldersTool(_ call: ToolCall) async -> String {
        guard let symbol = decodeArgs(call, as: StockSymbolArgs.self)?.symbol,
              let normalized = StocksStore.normalizeSymbol(symbol) else {
            return errorJSON("invalid or missing 'symbol'")
        }
        await StocksStore.shared.fetchHolders(symbol: normalized)
        let holders = StocksStore.shared.holdersCache[normalized] ?? []
        if holders.isEmpty {
            return jsonString(["status": "no_data", "symbol": normalized,
                               "message": "No institutional holder data found. May not be a US-listed stock or data unavailable."])
        }
        return jsonString([
            "status": "ok", "symbol": normalized, "holder_count": holders.count,
            "holders": holders.map { h in
                var dict: [String: Any] = ["name": h.holderName]
                if let pct = h.percentHeld { dict["percent_held"] = pct * 100 }
                if let shares = h.sharesHeld { dict["shares_held"] = shares }
                if let chg = h.changeShares { dict["change_shares"] = chg }
                if let date = h.dateReported { dict["date_reported"] = date }
                return dict
            },
        ])
    }

    @MainActor
    static func stockInsiderTool(_ call: ToolCall) async -> String {
        guard let symbol = decodeArgs(call, as: StockInsiderArgs.self)?.symbol,
              let normalized = StocksStore.normalizeSymbol(symbol) else {
            return errorJSON("invalid or missing 'symbol'")
        }
        await StocksStore.shared.fetchInsiderTransactions(symbol: normalized)
        let txs = StocksStore.shared.insiderCache[normalized] ?? []
        if txs.isEmpty {
            return jsonString(["status": "no_data", "symbol": normalized,
                               "message": "No insider transactions found. SEC EDGAR covers US-listed companies only."])
        }
        return jsonString([
            "status": "ok", "symbol": normalized, "transaction_count": txs.count,
            "transactions": txs.prefix(30).map { tx in
                var dict: [String: Any] = [
                    "insider": tx.insiderName, "type": tx.transactionType,
                ]
                if let t = tx.title { dict["title"] = t }
                if let s = tx.shares { dict["shares"] = s }
                if let p = tx.pricePerShare { dict["price_per_share"] = p }
                if let tv = tx.totalValue { dict["total_value"] = tv }
                if let d = tx.transactionDate { dict["date"] = d }
                return dict
            },
        ])
    }

    @MainActor
    static func stockProxyTool(_ call: ToolCall) async -> String {
        guard let symbol = decodeArgs(call, as: StockSymbolArgs.self)?.symbol,
              let normalized = StocksStore.normalizeSymbol(symbol) else {
            return errorJSON("invalid or missing 'symbol'")
        }
        await StocksStore.shared.fetchProxyFilings(symbol: normalized)
        let filings = StocksStore.shared.proxyCache[normalized] ?? []
        if filings.isEmpty {
            return jsonString(["status": "no_data", "symbol": normalized,
                               "message": "No proxy filings found. SEC EDGAR covers US-listed companies only."])
        }
        return jsonString([
            "status": "ok", "symbol": normalized, "filing_count": filings.count,
            "filings": filings.prefix(5).map { f in
                var dict: [String: Any] = [
                    "filing_date": f.filingDate,
                ]
                if let name = f.companyName { dict["company"] = name }
                if let meeting = f.meetingDate { dict["meeting_date"] = meeting }
                if let url = f.url { dict["url"] = url }
                if let proposals = f.proposals { dict["proposals"] = proposals }
                if let board = f.boardMembers { dict["board_members"] = board }
                return dict
            },
        ])
    }

    @MainActor
    static func stockInvestigateTool(_ call: ToolCall) async -> String {
        guard let symbol = decodeArgs(call, as: StockSymbolArgs.self)?.symbol,
              let normalized = StocksStore.normalizeSymbol(symbol) else {
            return errorJSON("invalid or missing 'symbol'")
        }
        let store = StocksStore.shared
        // Add to watchlist if not already there
        if !store.watchlist.contains(where: { $0.symbol == normalized }) {
            _ = store.add(symbol: normalized)
        }
        // Fetch everything in parallel
        async let quoteTask = store.quote(for: normalized)
        async let holdersTask: () = store.fetchHolders(symbol: normalized)
        async let insiderTask: () = store.fetchInsiderTransactions(symbol: normalized)
        async let proxyTask: () = store.fetchProxyFilings(symbol: normalized)
        let (quote, _, _, _) = await (quoteTask, holdersTask, insiderTask, proxyTask)

        let holders = store.holdersCache[normalized] ?? []
        let insiders = store.insiderCache[normalized] ?? []
        let proxies = store.proxyCache[normalized] ?? []

        var result: [String: Any] = ["status": "ok", "symbol": normalized]
        if let q = quote {
            result["price"] = q.price
            result["change_percent"] = q.changePercent as Any
        }
        result["holders"] = ["count": holders.count, "top": holders.prefix(5).map { $0.holderName }]
        result["insider_transactions"] = ["count": insiders.count,
                                          "recent_buys": insiders.filter { $0.transactionType == "Purchase" }.count,
                                          "recent_sells": insiders.filter { $0.transactionType == "Sale" }.count]
        result["proxy_filings"] = ["count": proxies.count,
                                   "latest": proxies.first?.filingDate ?? "none"]
        return jsonString(result)
    }

    @MainActor
    static func stockNoteTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: StockNoteArgs.self)
        guard let symbol = args?.symbol,
              let normalized = StocksStore.normalizeSymbol(symbol) else {
            return errorJSON("invalid or missing 'symbol'")
        }
        guard let note = args?.note, !note.trimmingCharacters(in: .whitespaces).isEmpty else {
            return errorJSON("'note' content is required")
        }
        guard let saved = StocksStore.shared.addNote(symbol: normalized, content: note) else {
            return errorJSON("failed to save note")
        }
        return jsonString(["status": "saved", "symbol": normalized, "note_id": saved.id])
    }

    @MainActor
    static func stockFlagTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: StockFlagArgs.self)
        guard let symbol = args?.symbol,
              let normalized = StocksStore.normalizeSymbol(symbol) else {
            return errorJSON("invalid or missing 'symbol'")
        }
        let store = StocksStore.shared
        guard let stock = store.trackedStocks.first(where: { $0.symbol == normalized }) else {
            return errorJSON("'\(normalized)' is not in the tracked stocks. Add it first with add_stock or stock_investigate.")
        }
        let action = args?.action?.lowercased() ?? "flag"
        switch action {
        case "flag":
            store.flagStock(id: stock.id, reason: args?.reason ?? "Flagged by agent")
            return jsonString(["status": "flagged", "symbol": normalized])
        case "unflag":
            store.unflagStock(id: stock.id)
            return jsonString(["status": "unflagged", "symbol": normalized])
        default:
            return errorJSON("unknown action '\(action)' — use 'flag' or 'unflag'")
        }
    }

    // MARK: - News argument types

    private struct OpenNewsArgs: Codable { let url: String?; let search: String? }

    // MARK: - News implementations

    static func openAppleNewsTool(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: OpenNewsArgs.self)
        let ok = await sharedNewsService.openNews(url: args?.url, search: args?.search)
        return ok
            ? jsonString(["status": "opened", "url": args?.url ?? "", "search": args?.search ?? ""])
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
}
