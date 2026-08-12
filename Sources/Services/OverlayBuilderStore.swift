import SwiftUI
import Observation

// MARK: - Canvas Size Presets

/// Simple struct for canvas size presets — avoids enum metadata issues in @Observable.
struct CanvasSizePreset: Sendable {
    let name: String
    let w: Int
    let h: Int
    let group: String
    var label: String { "\(name) (\(w)×\(h))" }
}

enum CanvasSizePresets {
    static let all: [CanvasSizePreset] = [
        CanvasSizePreset(name: "1080p",      w: 1920, h: 1080, group: "Video"),
        CanvasSizePreset(name: "720p",       w: 1280, h: 720,  group: "Video"),
        CanvasSizePreset(name: "4K UHD",     w: 3840, h: 2160, group: "Video"),
        CanvasSizePreset(name: "YouTube 1440p", w: 2560, h: 1440, group: "Video"),
        CanvasSizePreset(name: "TikTok / Reels / Shorts", w: 1080, h: 1920, group: "Social (9:16)"),
        CanvasSizePreset(name: "Instagram Square", w: 1080, h: 1080, group: "Instagram"),
        CanvasSizePreset(name: "Instagram Portrait", w: 1080, h: 1350, group: "Instagram"),
        CanvasSizePreset(name: "Instagram Landscape", w: 1080, h: 566, group: "Instagram"),
        CanvasSizePreset(name: "Facebook Link", w: 1200, h: 628, group: "Social"),
        CanvasSizePreset(name: "Twitter/X Card", w: 1200, h: 675, group: "Social"),
        CanvasSizePreset(name: "Icon 512",   w: 512,  h: 512,  group: "Other"),
    ]
    static let customIndex = 11
}

// MARK: - Overlay Type

/// The kind of overlay being built.
enum OverlayType: String, CaseIterable, Codable, Sendable, Identifiable {
    case lowerThird
    case lowerThirdIcon
    case titleCard
    case chapter
    case ticker
    case alert
    case webcamFrame
    case cornerBug
    case infoPill
    case stepCounter
    case webLink
    case countdown
    case brb
    case ending

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lowerThird:       return "Lower Third"
        case .lowerThirdIcon:   return "Lower Third + Icon"
        case .titleCard:        return "Title Card"
        case .chapter:          return "Chapter"
        case .ticker:           return "News Ticker"
        case .alert:            return "Alert Banner"
        case .webcamFrame:      return "Webcam Frame"
        case .cornerBug:        return "Corner Bug"
        case .infoPill:         return "Info Pill"
        case .stepCounter:      return "Step Counter"
        case .webLink:          return "URL / QR"
        case .countdown:        return "Countdown"
        case .brb:              return "Be Right Back"
        case .ending:           return "Stream Ending"
        }
    }

    var icon: String {
        switch self {
        case .lowerThird:       return "text.alignleft"
        case .lowerThirdIcon:   return "text.alignleft"
        case .titleCard:        return "film"
        case .chapter:          return "book"
        case .ticker:           return "scroll"
        case .alert:            return "bell.badge"
        case .webcamFrame:      return "rectangle.on.rectangle"
        case .cornerBug:        return "pin"
        case .infoPill:         return "info.circle"
        case .stepCounter:      return "number"
        case .webLink:          return "link"
        case .countdown:        return "clock"
        case .brb:              return "pause.circle"
        case .ending:           return "stop.circle"
        }
    }

    var group: String {
        switch self {
        case .lowerThird, .lowerThirdIcon: return "Lower Thirds"
        case .titleCard, .chapter:         return "Titles"
        case .ticker, .alert, .webcamFrame, .cornerBug: return "Streaming"
        case .infoPill, .stepCounter, .webLink:          return "Info"
        case .countdown, .brb, .ending:    return "Scenes"
        }
    }
}

// MARK: - Overlay Config

/// All editable fields for a single overlay, stored as a string dictionary
/// for maximum flexibility — the view interprets types at render time.
struct OverlayConfig: Codable, Equatable, Sendable {
    var type: OverlayType
    var fields: [String: String]

    static func defaults(for type: OverlayType) -> OverlayConfig {
        var fields: [String: String] = [:]
        switch type {
        case .lowerThird:
            fields = ["title": "John Smith", "subtitle": "Senior Engineer", "accent": "#7c3aed",
                      "barWidth": "5", "titleSize": "34", "subtitleSize": "16",
                      "lineSpacing": "6", "letterSpacing": "0",
                      "posX": "60", "posY": "900"]
        case .lowerThirdIcon:
            fields = ["title": "John Smith", "subtitle": "Senior Engineer", "accent": "#6366f1",
                      "iconEmoji": "⭐", "titleSize": "34", "subtitleSize": "16",
                      "lineSpacing": "6", "letterSpacing": "0",
                      "posX": "60", "posY": "900"]
        case .titleCard:
            fields = ["title": "Live Stream", "subtitle": "Welcome", "tagline": "",
                      "accent": "#7c3aed", "bgColor": "#0c0c12", "fontSize": "72",
                      "posX": "0", "posY": "0"]
        case .chapter:
            fields = ["num": "01", "title": "Introduction", "accent": "#7c3aed", "bgColor": "#0c0c12",
                      "posX": "0", "posY": "0"]
        case .ticker:
            fields = ["text": "BREAKING: Major update released", "accent": "#22c55e",
                      "label": "LIVE", "labelBg": "#ef4444",
                      "posX": "0", "posY": "0"]
        case .alert:
            fields = ["title": "New Follower!", "subtitle": "username", "accent": "#ef4444", "icon": "🔔",
                      "posX": "0", "posY": "0"]
        case .webcamFrame:
            fields = ["accent": "#7c3aed", "borderWidth": "4", "cornerRadius": "16",
                      "width": "400", "height": "300", "posX": "1460", "posY": "60"]
        case .cornerBug:
            fields = ["text": "LIVE", "accent": "#ef4444", "posX": "1800", "posY": "40"]
        case .infoPill:
            fields = ["label": "Model Name", "badge": "122B", "accent": "#22c55e",
                      "posX": "1600", "posY": "60"]
        case .stepCounter:
            fields = ["step": "3", "total": "7", "label": "Processing...", "accent": "#7c3aed",
                      "posX": "60", "posY": "60"]
        case .webLink:
            fields = ["label": "Visit", "url": "example.com", "accent": "#7c3aed",
                      "posX": "1560", "posY": "920"]
        case .countdown:
            fields = ["hours": "0", "minutes": "05", "seconds": "00",
                      "label": "Starting soon", "accent": "#f97316", "bgColor": "#0c0c12",
                      "posX": "0", "posY": "0"]
        case .brb:
            fields = ["title": "Be Right Back", "subtitle": "Stream will resume shortly",
                      "accent": "#eab308", "bgColor": "#0c0c12",
                      "posX": "0", "posY": "0"]
        case .ending:
            fields = ["title": "Thanks for Watching", "subtitle": "See you next time",
                      "socials": "@username", "accent": "#ec4899", "bgColor": "#0c0c12",
                      "posX": "0", "posY": "0"]
        }
        return OverlayConfig(type: type, fields: fields)
    }
}

// MARK: - Overlay Builder Store

/// Persists overlay configurations and manages the builder state.
@Observable
@MainActor
final class OverlayBuilderStore {
    static let shared = OverlayBuilderStore()

    /// All saved overlay presets, keyed by name.
    var presets: [String: OverlayConfig] = [:]

    /// Currently selected overlay type.
    var selectedType: OverlayType = .lowerThird

    /// Current field values for the active overlay.
    var currentFields: [String: String] = [:]

    /// Global style settings.
    var globalFont: String = "system"
    var globalOpacity: Double = 92
    var globalCornerRadius: Double = 14

    /// Safe area settings.
    var safeAreaOpacity: Double = 30   // 10-60%
    var safeAreaStyle: Int = 0         // 0=outline, 1=fill, 2=both
    var safeAreaColorHex: String = "#ffffff"

    /// Canvas size preset index.
    var canvasSizeIndex: Int = 0
    var customWidth: Int = 1920
    var customHeight: Int = 1080

    /// Effective canvas dimensions (resolves custom sizes).
    var canvasWidth: Int {
        canvasSizeIndex < CanvasSizePresets.all.count
            ? CanvasSizePresets.all[canvasSizeIndex].w : customWidth
    }
    var canvasHeight: Int {
        canvasSizeIndex < CanvasSizePresets.all.count
            ? CanvasSizePresets.all[canvasSizeIndex].h : customHeight
    }

    private let presetsKey = "overlayBuilder.presets"
    private let globalsKey = "overlayBuilder.globals"

    private init() {
        loadPresets()
        loadGlobals()
        if currentFields.isEmpty {
            currentFields = OverlayConfig.defaults(for: selectedType).fields
        }
    }

    // MARK: - Persistence

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let decoded = try? JSONDecoder().decode([String: OverlayConfig].self, from: data)
        else { return }
        presets = decoded
    }

    func savePresets() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: presetsKey)
    }

    private func loadGlobals() {
        guard let data = UserDefaults.standard.data(forKey: globalsKey),
              let decoded = try? JSONDecoder().decode(Globals.self, from: data)
        else { return }
        globalFont = decoded.font
        globalOpacity = decoded.opacity
        globalCornerRadius = decoded.cornerRadius
        canvasSizeIndex = decoded.canvasSizeIndex ?? 0
        customWidth = decoded.customWidth ?? 1920
        customHeight = decoded.customHeight ?? 1080
        safeAreaOpacity = decoded.safeAreaOpacity ?? 30
        safeAreaStyle = decoded.safeAreaStyle ?? 0
        safeAreaColorHex = decoded.safeAreaColorHex ?? "#ffffff"
    }

    func saveGlobals() {
        let g = Globals(font: globalFont, opacity: globalOpacity, cornerRadius: globalCornerRadius,
                        canvasSizeIndex: canvasSizeIndex, customWidth: customWidth, customHeight: customHeight,
                        safeAreaOpacity: safeAreaOpacity, safeAreaStyle: safeAreaStyle, safeAreaColorHex: safeAreaColorHex)
        guard let data = try? JSONEncoder().encode(g) else { return }
        UserDefaults.standard.set(data, forKey: globalsKey)
    }

    struct Globals: Codable {
        var font: String
        var opacity: Double
        var cornerRadius: Double
        var canvasSizeIndex: Int?
        var customWidth: Int?
        var customHeight: Int?
        var safeAreaOpacity: Double?
        var safeAreaStyle: Int?
        var safeAreaColorHex: String?
    }

    // MARK: - Preset Management

    func saveCurrentAsPreset(name: String) {
        let config = OverlayConfig(type: selectedType, fields: currentFields)
        presets[name] = config
        savePresets()
    }

    func loadPreset(name: String) {
        guard let config = presets[name] else { return }
        selectedType = config.type
        currentFields = config.fields
    }

    func deletePreset(name: String) {
        presets.removeValue(forKey: name)
        savePresets()
    }

    func selectType(_ type: OverlayType) {
        selectedType = type
        // Load defaults if switching type, keep current fields if same
        if currentFields.isEmpty {
            currentFields = OverlayConfig.defaults(for: type).fields
        }
    }

    func resetToDefaults() {
        currentFields = OverlayConfig.defaults(for: selectedType).fields
    }

    // MARK: - Field Access

    func field(_ key: String) -> String {
        currentFields[key] ?? ""
    }

    func setField(_ key: String, value: String) {
        currentFields[key] = value
    }

    func colorField(_ key: String) -> Color {
        Color(hex6: currentFields[key] ?? "#7c3aed")
    }

    func numField(_ key: String) -> Double {
        Double(currentFields[key] ?? "0") ?? 0
    }
}

// MARK: - Color Hex Init

extension Color {
    /// Parse a 6-digit `#RRGGBB` hex string.
    init(hex6: String) {
        var hex = hex6.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hex.count == 6 { hex = hex + "ff" }
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b, a: UInt64
        (r, g, b, a) = (int >> 24 & 0xFF, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }

    var hexString: String {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components else { return "#000000" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
