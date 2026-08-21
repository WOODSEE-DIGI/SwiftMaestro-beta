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
    case htmlEditor

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
        case .htmlEditor:       return "HTML / CSS Editor"
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
        case .htmlEditor:       return "chevron.left.forwardslash.chevron.right"
        }
    }

    var group: String {
        switch self {
        case .lowerThird, .lowerThirdIcon: return "Lower Thirds"
        case .titleCard, .chapter:         return "Titles"
        case .ticker, .alert, .webcamFrame, .cornerBug: return "Streaming"
        case .infoPill, .stepCounter, .webLink:          return "Info"
        case .countdown, .brb, .ending:    return "Scenes"
        // htmlEditor is pinned separately in the sidebar (not in a group).
        case .htmlEditor:                   return ""
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
        case .htmlEditor:
            fields = ["html": OverlayHTMLEditorView.defaultHTML,
                      "css": OverlayHTMLEditorView.defaultCSS,
                      "posX": "0", "posY": "0"]
        }
        return OverlayConfig(type: type, fields: fields)
    }
}

// MARK: - Overlay Builder Store

/// Persists overlay configurations and manages the builder state.
///
/// Persistence model: EVERY overlay type remembers its own settings, always.
/// Each edit is saved into `typeDrafts[type]` immediately — no presets, no
/// save button, no linking. Switching types and relaunching the app always
/// restores exactly what you last saw.
/// Shared HTML/CSS editor defaults, referenced by `OverlayBuilderStore`'s
/// hoisted editor state. Lives here (Services) so the store compiles without
/// duplicating the long default strings; the actual source of truth is still
/// `OverlayHTMLEditorView.defaultHTML/defaultCSS`.
enum OverlayHTMLEditorDefaults {
    static let html = """
    <div class="overlay">
      <div class="accent-bar"></div>
      <div class="content">
        <div class="title">Your Title Here</div>
        <div class="subtitle">Subtitle text goes here</div>
      </div>
    </div>
    """

    static let css = """
    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif;
      background: transparent;
      width: 1920px;
      height: 1080px;
      overflow: hidden;
    }

    .overlay {
      position: absolute;
      left: 60px;
      bottom: 80px;
      display: flex;
      flex-direction: row;
      align-items: stretch;
      gap: 0;
    }

    .accent-bar {
      width: 5px;
      background: #7c3aed;
      border-radius: 3px 0 0 3px;
    }

    .content {
      background: rgba(12, 12, 18, 0.92);
      border: 1px solid rgba(124, 58, 237, 0.3);
      border-left: none;
      border-radius: 0 10px 10px 0;
      padding: 18px 28px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .title {
      color: #ffffff;
      font-size: 34px;
      font-weight: 600;
      letter-spacing: -0.3px;
    }

    .subtitle {
      color: rgba(255, 255, 255, 0.7);
      font-size: 16px;
      font-weight: 400;
    }
    """
}

@Observable
@MainActor
final class OverlayBuilderStore {
    static let shared = OverlayBuilderStore()

    /// Currently selected overlay type.
    var selectedType: OverlayType = .lowerThird

    /// HTML/CSS editor source, hoisted from OverlayHTMLEditorView so agent
    /// tools (overlay_html_get/set) can read and modify the live document.
    /// The editor binds directly to these; edits from either side update the
    /// preview immediately.
    var htmlEditorSource: String = OverlayHTMLEditorDefaults.html
    var cssEditorSource: String = OverlayHTMLEditorDefaults.css

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

    private let globalsKey = "overlayBuilder.globals"
    private let currentTypeKey = "overlayBuilder.currentType"
    private let typeDraftsKey = "overlayBuilder.typeDrafts"

    /// The saved settings for every overlay type (OverlayType.rawValue →
    /// fields). This IS the save — every edit lands here immediately.
    private var typeDrafts: [String: [String: String]] = [:]

    private init() {
        loadGlobals()
        loadTypeDraftsMigratingLegacyPresets()
        if let typeRaw = UserDefaults.standard.string(forKey: currentTypeKey),
           let type = OverlayType(rawValue: typeRaw) {
            selectedType = type
        }
        currentFields = typeDrafts[selectedType.rawValue]
            ?? Self.legacyCurrentFields(for: selectedType)
            ?? OverlayConfig.defaults(for: selectedType).fields
        typeDrafts[selectedType.rawValue] = currentFields
    }

    // MARK: - Persistence

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

    /// Persist everything: all type drafts + the selected type + globals.
    private func autosave() {
        if let data = try? JSONEncoder().encode(typeDrafts) {
            UserDefaults.standard.set(data, forKey: typeDraftsKey)
        }
        UserDefaults.standard.set(selectedType.rawValue, forKey: currentTypeKey)
        saveGlobals()
    }

    // MARK: - Legacy Migration (presets → per-type saved settings)

    /// Seeds typeDrafts from the removed preset system, then archives the old
    /// keys (nothing user-created is deleted). Each type's alphabetically-first
    /// preset becomes that type's saved settings; the linked/draft state from
    /// the preset era is folded in via `legacyCurrentFields`.
    private func loadTypeDraftsMigratingLegacyPresets() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: typeDraftsKey),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            typeDrafts = decoded
        }

        let legacyPresetsKey = "overlayBuilder.presets"
        guard let data = defaults.data(forKey: legacyPresetsKey),
              let presets = try? JSONDecoder().decode([String: OverlayConfig].self, from: data),
              !presets.isEmpty else { return }

        // Alphabetically-first preset per type wins that type's saved settings.
        for config in presets.sorted(by: { $0.key < $1.key }).map(\.value) {
            let key = config.type.rawValue
            if typeDrafts[key] == nil {
                typeDrafts[key] = config.fields
            }
        }

        // Archive, never delete (backup-before-destructive rule).
        defaults.set(data, forKey: legacyPresetsKey + ".archived")
        defaults.removeObject(forKey: legacyPresetsKey)
        defaults.removeObject(forKey: "overlayBuilder.activePreset")
    }

    /// The preset-era "current draft" key — only meaningful if its type matches.
    private static func legacyCurrentFields(for type: OverlayType) -> [String: String]? {
        let defaults = UserDefaults.standard
        guard let typeRaw = defaults.string(forKey: "overlayBuilder.currentType"),
              typeRaw == type.rawValue,
              let data = defaults.data(forKey: "overlayBuilder.currentFields"),
              let fields = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        defaults.removeObject(forKey: "overlayBuilder.currentFields")
        return fields
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

    /// Applies a website template: loads its HTML/CSS into the editor and,
    /// for fixed-size assets (Avatar 512px, Banner 1500x500), resizes the
    /// canvas to the template's natural dimensions so the preview and PNG
    /// export come out pixel-exact. Shared by the sidebar, the editor's
    /// Template menu, and the overlay_html_template agent tool.
    func applyWebsiteTemplate(_ template: WebsiteTemplate) {
        htmlEditorSource = template.html
        cssEditorSource = template.css
        if let w = template.canvasWidth, let h = template.canvasHeight {
            canvasSizeIndex = CanvasSizePresets.customIndex
            customWidth = w
            customHeight = h
        }
        if selectedType != .htmlEditor {
            selectType(.htmlEditor)
        }
    }

    // MARK: - Type Selection

    func selectType(_ type: OverlayType) {
        guard type != selectedType else { return }
        // currentFields is already saved per edit, but flush once more so a
        // mid-drag (setFieldLive) position is never lost on type switch.
        typeDrafts[selectedType.rawValue] = currentFields
        selectedType = type
        currentFields = typeDrafts[type.rawValue] ?? OverlayConfig.defaults(for: type).fields
        autosave()
    }

    func resetToDefaults() {
        currentFields = OverlayConfig.defaults(for: selectedType).fields
        typeDrafts[selectedType.rawValue] = currentFields
        autosave()
    }

    // MARK: - Field Access

    func field(_ key: String) -> String {
        currentFields[key] ?? ""
    }

    func setField(_ key: String, value: String) {
        currentFields[key] = value
        typeDrafts[selectedType.rawValue] = currentFields
        autosave()
    }

    /// Update a field WITHOUT persisting — pair with `flushDraft()` when the
    /// interaction ends. Keeps mouse-rate events (drag-to-move) from
    /// JSON-encoding and writing UserDefaults per frame.
    func setFieldLive(_ key: String, value: String) {
        currentFields[key] = value
        typeDrafts[selectedType.rawValue] = currentFields
    }

    /// Persist after a batch of live updates.
    func flushDraft() {
        autosave()
    }

    func colorField(_ key: String) -> Color {
        Color(hex6: currentFields[key] ?? "#7c3aed")
    }

    // MARK: - Image Cache

    /// Path-keyed image cache. The Canvas draw closure and inspector thumbnail
    /// used to `NSImage(contentsOfFile:)` on every redraw — re-reading and
    /// re-decoding the file per keystroke. Untracked on purpose: populating
    /// the cache during rendering must not trigger view invalidation.
    @ObservationIgnored
    private var imageCache: [String: NSImage] = [:]

    func image(atPath path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let cached = imageCache[path] { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        if imageCache.count > 20 { imageCache.removeAll() }
        imageCache[path] = image
        return image
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
