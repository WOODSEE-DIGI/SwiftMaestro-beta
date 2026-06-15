import SwiftUI
import AppKit

/// User-customizable UI theme: a light/dark appearance override plus optional
/// color overrides for the accent and the user's chat bubble. Overrides are
/// stored as sRGB hex in UserDefaults; when an override is absent the app keeps
/// its default look (the system accent / white bubble text), so a fresh install
/// looks exactly as before until the user customizes something.
@Observable
@MainActor
final class ThemeStore {

    /// Window appearance: follow the system, or force light/dark.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        /// `nil` follows the system; otherwise forces the scheme.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    private static let appearanceKey = "theme.appearance"
    private static let accentKey = "theme.accentHex"
    private static let userBubbleKey = "theme.userBubbleHex"
    private static let userBubbleTextKey = "theme.userBubbleTextHex"
    private static let chatBackgroundKey = "theme.chatBackgroundHex"
    private static let sidebarKey = "theme.sidebarHex"
    private static let sidebarTextKey = "theme.sidebarTextHex"
    private static let plansPanelKey = "theme.plansPanelHex"
    private static let tasksPanelKey = "theme.tasksPanelHex"

    /// Subtle neutral tint used by the side panels unless the user overrides them.
    static let defaultPanelTint = Color.secondary.opacity(0.04)

    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    /// In-memory color overrides — the live source of truth for this session.
    /// Kept as `Color` rather than re-derived from hex on every read, so dragging
    /// the system color panel's brightness slider doesn't round-trip through
    /// 8-bit hex (which quantizes RGB and destabilizes the wheel's hue/saturation,
    /// making the selection point jump). Hex is written only for persistence.
    /// `nil` => use the default color below.
    private var accentOverride: Color?
    private var userBubbleOverride: Color?
    private var userBubbleTextOverride: Color?
    private var chatBackgroundOverride: Color?
    private var sidebarOverride: Color?
    private var sidebarTextOverride: Color?
    private var plansPanelOverride: Color?
    private var tasksPanelOverride: Color?

    init() {
        let defaults = UserDefaults.standard
        appearance = Appearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "")
            ?? .system
        accentOverride = defaults.string(forKey: Self.accentKey).flatMap(Color.init(hex:))
        userBubbleOverride = defaults.string(forKey: Self.userBubbleKey).flatMap(Color.init(hex:))
        userBubbleTextOverride = defaults.string(forKey: Self.userBubbleTextKey).flatMap(Color.init(hex:))
        chatBackgroundOverride = defaults.string(forKey: Self.chatBackgroundKey).flatMap(Color.init(hex:))
        sidebarOverride = defaults.string(forKey: Self.sidebarKey).flatMap(Color.init(hex:))
        sidebarTextOverride = defaults.string(forKey: Self.sidebarTextKey).flatMap(Color.init(hex:))
        plansPanelOverride = defaults.string(forKey: Self.plansPanelKey).flatMap(Color.init(hex:))
        tasksPanelOverride = defaults.string(forKey: Self.tasksPanelKey).flatMap(Color.init(hex:))
    }

    // MARK: - Effective colors (override, else the app default)

    /// Tints buttons, selection, and plan cards. Defaults to the system accent.
    var accent: Color { accentOverride ?? .accentColor }
    /// Background of the user's chat bubble. Defaults to the system accent.
    var userBubble: Color { userBubbleOverride ?? .accentColor }
    /// Text color inside the user's chat bubble. Defaults to white.
    var userBubbleText: Color { userBubbleTextOverride ?? .white }
    /// Main chat area background. Defaults to the real system window background
    /// (not `.clear`) so the color picker opens on the actual color instead of a
    /// black/transparent swatch, while still matching the system look.
    var chatBackground: Color { chatBackgroundOverride ?? Color(nsColor: .windowBackgroundColor) }
    /// Agent sidebar background. Defaults to the system window background for the
    /// picker; the view only replaces the list's material when `sidebarOverridden`.
    var sidebarBackground: Color { sidebarOverride ?? Color(nsColor: .windowBackgroundColor) }
    /// Whether a custom sidebar color is set.
    var sidebarOverridden: Bool { sidebarOverride != nil }
    /// Sidebar row (agent name) text. Defaults to full-strength `.primary` so it
    /// reads at the same brightness as content text instead of the muted vibrant
    /// label macOS applies to sidebar lists by default.
    var sidebarText: Color { sidebarTextOverride ?? .primary }
    /// Plans side panel background. Defaults to the subtle neutral tint.
    var plansPanel: Color { plansPanelOverride ?? Self.defaultPanelTint }
    /// Tasks side panel background. Defaults to the subtle neutral tint.
    var tasksPanel: Color { tasksPanelOverride ?? Self.defaultPanelTint }

    /// True when any color has been customized (drives the Reset button).
    var hasColorOverrides: Bool {
        accentOverride != nil || userBubbleOverride != nil || userBubbleTextOverride != nil
            || chatBackgroundOverride != nil || sidebarOverride != nil || sidebarTextOverride != nil
            || plansPanelOverride != nil || tasksPanelOverride != nil
    }

    // MARK: - ColorPicker bindings

    var accentBinding: Binding<Color> {
        Binding(get: { self.accent }, set: { self.setAccent($0) })
    }
    var userBubbleBinding: Binding<Color> {
        Binding(get: { self.userBubble }, set: { self.setUserBubble($0) })
    }
    var userBubbleTextBinding: Binding<Color> {
        Binding(get: { self.userBubbleText }, set: { self.setUserBubbleText($0) })
    }
    var chatBackgroundBinding: Binding<Color> {
        Binding(get: { self.chatBackground }, set: { self.setChatBackground($0) })
    }
    var sidebarBinding: Binding<Color> {
        Binding(get: { self.sidebarBackground }, set: { self.setSidebar($0) })
    }
    var sidebarTextBinding: Binding<Color> {
        Binding(get: { self.sidebarText }, set: { self.setSidebarText($0) })
    }
    var plansPanelBinding: Binding<Color> {
        Binding(get: { self.plansPanel }, set: { self.setPlansPanel($0) })
    }
    var tasksPanelBinding: Binding<Color> {
        Binding(get: { self.tasksPanel }, set: { self.setTasksPanel($0) })
    }

    func setAccent(_ color: Color) { accentOverride = color; persist(Self.accentKey, color) }
    func setUserBubble(_ color: Color) { userBubbleOverride = color; persist(Self.userBubbleKey, color) }
    func setUserBubbleText(_ color: Color) { userBubbleTextOverride = color; persist(Self.userBubbleTextKey, color) }
    func setChatBackground(_ color: Color) { chatBackgroundOverride = color; persist(Self.chatBackgroundKey, color) }
    func setSidebar(_ color: Color) { sidebarOverride = color; persist(Self.sidebarKey, color) }
    func setSidebarText(_ color: Color) { sidebarTextOverride = color; persist(Self.sidebarTextKey, color) }
    func setPlansPanel(_ color: Color) { plansPanelOverride = color; persist(Self.plansPanelKey, color) }
    func setTasksPanel(_ color: Color) { tasksPanelOverride = color; persist(Self.tasksPanelKey, color) }

    /// Clear all color overrides (back to the system accent / white text).
    func resetColors() {
        accentOverride = nil
        userBubbleOverride = nil
        userBubbleTextOverride = nil
        chatBackgroundOverride = nil
        sidebarOverride = nil
        sidebarTextOverride = nil
        plansPanelOverride = nil
        tasksPanelOverride = nil
        for key in [
            Self.accentKey, Self.userBubbleKey, Self.userBubbleTextKey,
            Self.chatBackgroundKey, Self.sidebarKey, Self.sidebarTextKey,
            Self.plansPanelKey, Self.tasksPanelKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Persist a color as sRGB hex (lossy 8-bit is fine for storage; it never
    /// feeds back into the live picker, which uses the in-memory `Color`).
    private func persist(_ key: String, _ color: Color) {
        if let hex = color.hexRGBA { UserDefaults.standard.set(hex, forKey: key) }
    }
}

// MARK: - Color <-> hex (sRGB, 8-digit RRGGBBAA)

extension Color {
    /// Parse an 8-digit `RRGGBBAA` hex string (leading `#` optional).
    init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 8, let value = UInt64(string, radix: 16) else { return nil }
        self = Color(
            .sRGB,
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            opacity: Double(value & 0xFF) / 255)
    }

    /// Serialize to an 8-digit `RRGGBBAA` hex string in sRGB. Returns `nil` if
    /// the color can't be resolved into sRGB components.
    var hexRGBA: String? {
        guard let resolved = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = UInt8((resolved.redComponent * 255).rounded())
        let g = UInt8((resolved.greenComponent * 255).rounded())
        let b = UInt8((resolved.blueComponent * 255).rounded())
        let a = UInt8((resolved.alphaComponent * 255).rounded())
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }
}
