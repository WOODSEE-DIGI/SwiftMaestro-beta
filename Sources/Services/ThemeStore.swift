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
    enum Appearance: String, CaseIterable, Identifiable, Codable {
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

    static let appearanceKey = "theme.appearance"
    static let accentKey = "theme.accentHex"
    static let userBubbleKey = "theme.userBubbleHex"
    static let userBubbleTextKey = "theme.userBubbleTextHex"
    static let chatBackgroundKey = "theme.chatBackgroundHex"
    static let chatTextKey = "theme.chatTextHex"
    static let chatSecondaryTextKey = "theme.chatSecondaryTextHex"
    /// Legacy keys from the retired luminance-tuning tier (a temporary tool
    /// for finding legible values; those values are now baked into the
    /// per-appearance defaults below). Deleted on launch.
    static let legacyGlobalBackgroundLuminanceKey = "theme.globalBackgroundLuminance"
    static let legacyGlobalTextLuminanceKey = "theme.globalTextLuminance"
    static let legacyGlobalTextFollowsContrastKey = "theme.globalTextFollowsContrast"
    static let sidebarKey = "theme.sidebarHex"
    static let sidebarTextKey = "theme.sidebarTextHex"
    static let plansPanelKey = "theme.plansPanelHex"
    static let plansCardKey = "theme.plansCardHex"
    static let plansTextKey = "theme.plansTextHex"
    static let tasksPanelKey = "theme.tasksPanelHex"
    static let tasksTextKey = "theme.tasksTextHex"
    static let backgroundKey = "theme.backgroundHex"
    static let secondaryBackgroundKey = "theme.secondaryBackgroundHex"
    /// Per-panel-kind color overrides (Calendar, Reminders, Contacts, ...),
    /// keyed by `WorkspacePanelKind.themeStorageKey`. Stored as a single JSON
    /// blob (`[storageKey: hex]`) rather than one UserDefaults key per panel —
    /// the panel list grows over time (new Apple app integrations, plugins),
    /// and a fixed set of named properties (like the sidebar/plans/chat/tasks
    /// overrides above) doesn't scale to that.
    static let panelAccentsKey = "theme.panelAccentsJSON"

    /// Subtle neutral tint kept for any view that still wants a translucent
    /// panel wash instead of the baked content gray.
    static let defaultPanelTint = Color.secondary.opacity(0.04)

    var appearance: Appearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
            Self.applyAppAppearance(appearance)
        }
    }

    /// Drive the app-level appearance from the theme choice. This makes
    /// `NSApp.effectiveAppearance` deterministic at every read — light/dark
    /// force it, `.system` releases it back to the OS — so `.system`
    /// resolution below is correct the instant the user clicks, not whenever
    /// the window scheme eventually settles.
    static func applyAppAppearance(_ appearance: Appearance) {
        switch appearance {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
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
    private var chatTextOverride: Color?
    private var chatSecondaryTextOverride: Color?
    private var sidebarOverride: Color?
    private var sidebarTextOverride: Color?
    private var plansPanelOverride: Color?
    private var plansCardOverride: Color?
    private var plansTextOverride: Color?
    private var tasksPanelOverride: Color?
    private var tasksTextOverride: Color?
    private var backgroundOverride: Color?
    private var secondaryBackgroundOverride: Color?

    /// Per-panel-kind overrides, keyed by `WorkspacePanelKind.themeStorageKey`.
    /// Absent key => that panel uses the shared `accent` color (see
    /// `panelAccent(for:)`). Internal so `SkinStore` can snapshot current colors.
    var panelAccentOverrides: [String: Color] = [:]

    init() {
        let defaults = UserDefaults.standard
        appearance = Appearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "")
            ?? .system
        Self.applyAppAppearance(appearance)
        accentOverride = defaults.string(forKey: Self.accentKey).flatMap(Color.init(hex:))
        userBubbleOverride = defaults.string(forKey: Self.userBubbleKey).flatMap(Color.init(hex:))
        userBubbleTextOverride = defaults.string(forKey: Self.userBubbleTextKey).flatMap(Color.init(hex:))
        chatBackgroundOverride = defaults.string(forKey: Self.chatBackgroundKey).flatMap(Color.init(hex:))
        chatTextOverride = defaults.string(forKey: Self.chatTextKey).flatMap(Color.init(hex:))
        chatSecondaryTextOverride = defaults.string(forKey: Self.chatSecondaryTextKey).flatMap(Color.init(hex:))
        Self.removeLegacyLuminanceKeys(defaults)
        sidebarOverride = defaults.string(forKey: Self.sidebarKey).flatMap(Color.init(hex:))
        sidebarTextOverride = defaults.string(forKey: Self.sidebarTextKey).flatMap(Color.init(hex:))
        plansPanelOverride = defaults.string(forKey: Self.plansPanelKey).flatMap(Color.init(hex:))
        plansCardOverride = defaults.string(forKey: Self.plansCardKey).flatMap(Color.init(hex:))
        plansTextOverride = defaults.string(forKey: Self.plansTextKey).flatMap(Color.init(hex:))
        tasksPanelOverride = defaults.string(forKey: Self.tasksPanelKey).flatMap(Color.init(hex:))
        tasksTextOverride = defaults.string(forKey: Self.tasksTextKey).flatMap(Color.init(hex:))
        backgroundOverride = defaults.string(forKey: Self.backgroundKey).flatMap(Color.init(hex:))
        secondaryBackgroundOverride = defaults.string(forKey: Self.secondaryBackgroundKey).flatMap(Color.init(hex:))
        panelAccentOverrides = Self.loadPanelAccents(from: defaults)
    }

    /// One-time cleanup of the retired luminance-tuning tier's keys. The
    /// values those sliders found are baked into `defaultContentBackground` /
    /// `defaultSecondaryBackground` below, so the keys only risk resurrecting
    /// the old "one slider fights the appearance picker" behavior.
    private static func removeLegacyLuminanceKeys(_ defaults: UserDefaults) {
        for key in [legacyGlobalBackgroundLuminanceKey, legacyGlobalTextLuminanceKey,
                    legacyGlobalTextFollowsContrastKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Re-read all persisted theme values. Used after a settings restore so the
    /// live store reflects the recovered UserDefaults without restarting the app.
    func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        appearance = Appearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "")
            ?? .system
        accentOverride = defaults.string(forKey: Self.accentKey).flatMap(Color.init(hex:))
        userBubbleOverride = defaults.string(forKey: Self.userBubbleKey).flatMap(Color.init(hex:))
        userBubbleTextOverride = defaults.string(forKey: Self.userBubbleTextKey).flatMap(Color.init(hex:))
        chatBackgroundOverride = defaults.string(forKey: Self.chatBackgroundKey).flatMap(Color.init(hex:))
        chatTextOverride = defaults.string(forKey: Self.chatTextKey).flatMap(Color.init(hex:))
        chatSecondaryTextOverride = defaults.string(forKey: Self.chatSecondaryTextKey).flatMap(Color.init(hex:))
        sidebarOverride = defaults.string(forKey: Self.sidebarKey).flatMap(Color.init(hex:))
        sidebarTextOverride = defaults.string(forKey: Self.sidebarTextKey).flatMap(Color.init(hex:))
        plansPanelOverride = defaults.string(forKey: Self.plansPanelKey).flatMap(Color.init(hex:))
        plansCardOverride = defaults.string(forKey: Self.plansCardKey).flatMap(Color.init(hex:))
        plansTextOverride = defaults.string(forKey: Self.plansTextKey).flatMap(Color.init(hex:))
        tasksPanelOverride = defaults.string(forKey: Self.tasksPanelKey).flatMap(Color.init(hex:))
        tasksTextOverride = defaults.string(forKey: Self.tasksTextKey).flatMap(Color.init(hex:))
        backgroundOverride = defaults.string(forKey: Self.backgroundKey).flatMap(Color.init(hex:))
        secondaryBackgroundOverride = defaults.string(forKey: Self.secondaryBackgroundKey).flatMap(Color.init(hex:))
        panelAccentOverrides = Self.loadPanelAccents(from: defaults)
    }

    private static func loadPanelAccents(from defaults: UserDefaults) -> [String: Color] {
        guard let data = defaults.data(forKey: panelAccentsKey),
              let hexByKey = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return hexByKey.compactMapValues(Color.init(hex:))
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
    // MARK: - Adaptive surface defaults
    //
    // Every surface resolves its text/icons against its OWN effective
    // background: an explicit override is honored and its text is
    // contrast-computed against it; with no override the surface uses the
    // appearance-appropriate baked default, again with contrast-computed text.
    // Light mode is light with dark text; dark mode is dark with light text —
    // legible by construction. (This replaces the temporary luminance-slider
    // tier, which was only ever a tuning tool for finding these defaults.)

    /// Whether the active appearance resolves to dark. `.system` reads the
    /// app-level appearance, which we drive ourselves (see
    /// `applyAppAppearance`), so this is deterministic at every read; view
    /// bodies re-evaluate on any scheme change, which refreshes it live.
    var isDarkAppearanceActive: Bool {
        switch appearance {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    /// Baked content-surface gray for the active appearance — the legible
    /// values found via the luminance tuning session: light mode sits at 88%,
    /// dark mode at 13%.
    var defaultContentBackground: Color { Self.grayColor(isDarkAppearanceActive ? 0.13 : 0.88) }
    /// Baked secondary surface (tool bars, input bar) — one step off the
    /// content gray so stacked bars stay distinguishable.
    var defaultSecondaryBackground: Color { Self.grayColor(isDarkAppearanceActive ? 0.19 : 0.82) }

    /// Main chat area background.
    var chatBackground: Color { chatBackgroundOverride ?? defaultContentBackground }
    /// Main chat text color for assistant messages — computed against the
    /// chat's effective background unless explicitly overridden.
    var chatText: Color { chatTextOverride ?? Self.contrastText(forBackground: chatBackground) }
    /// Agent sidebar background.
    var sidebarBackground: Color { sidebarOverride ?? defaultContentBackground }
    /// Whether a custom sidebar color is set.
    var sidebarOverridden: Bool { sidebarOverride != nil }
    /// Sidebar row (agent name) text — computed against the sidebar's own
    /// effective background unless explicitly overridden.
    var sidebarText: Color { sidebarTextOverride ?? Self.contrastText(forBackground: sidebarBackground) }
    /// Plans side panel background.
    var plansPanel: Color { plansPanelOverride ?? defaultContentBackground }
    /// Plan card (bubble) background. Defaults to the shared accent so cards
    /// stay accent pills until individually customized.
    var plansCard: Color { plansCardOverride ?? accent }
    /// Plan card title text. Explicitly settable; otherwise contrast-computed
    /// against the card's effective background (accent or custom) so it can
    /// never blend into the bubble.
    var plansCardText: Color { plansTextOverride ?? Self.contrastText(forBackground: plansCard) }
    /// Text that sits directly on the plans PANEL background (count badge,
    /// empty-state hints) — computed against the panel's effective background.
    var plansPanelText: Color { Self.contrastText(forBackground: plansPanel) }
    /// Tasks side panel background.
    var tasksPanel: Color { tasksPanelOverride ?? defaultContentBackground }
    /// Task (todo) title text for open items — computed against the panel's
    /// effective background unless explicitly overridden.
    var tasksText: Color { tasksTextOverride ?? Self.contrastText(forBackground: tasksPanel) }
    /// Generic view background (e.g. Notes editor).
    var background: Color { backgroundOverride ?? defaultContentBackground }
    /// Generic secondary background (e.g. Notes toolbar/search bar).
    var secondaryBackground: Color { secondaryBackgroundOverride ?? defaultSecondaryBackground }

    /// The tint a floating panel's header bar should use: that panel kind's
    /// own override if the user set one, else the shared `accent`. Every
    /// panel kind defaults to the SAME color (accent) until individually
    /// customized, matching how the other sections here default to a shared
    /// system color until overridden.
    func panelAccent(for kind: WorkspacePanelKind) -> Color {
        panelAccentOverrides[kind.themeStorageKey] ?? accent
    }

    /// The raw override for a panel kind, or `nil` if it's following the
    /// shared accent. Used by Settings to show "not yet customized" state.
    func panelAccentOverride(for kind: WorkspacePanelKind) -> Color? {
        panelAccentOverrides[kind.themeStorageKey]
    }

    /// True when any color has been customized (drives the Reset button).
    var hasColorOverrides: Bool {
        accentOverride != nil || userBubbleOverride != nil || userBubbleTextOverride != nil
            || chatBackgroundOverride != nil || chatTextOverride != nil || chatSecondaryTextOverride != nil
            || sidebarOverride != nil || sidebarTextOverride != nil
            || plansPanelOverride != nil || plansCardOverride != nil || plansTextOverride != nil
            || tasksPanelOverride != nil || tasksTextOverride != nil
            || backgroundOverride != nil || secondaryBackgroundOverride != nil
            || !panelAccentOverrides.isEmpty
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
    var chatTextBinding: Binding<Color> {
        Binding(get: { self.chatText }, set: { self.setChatText($0) })
    }
    var chatSecondaryTextBinding: Binding<Color> {
        Binding(get: { self.chatSecondaryText }, set: { self.setChatSecondaryText($0) })
    }
    var sidebarBinding: Binding<Color> {
        Binding(get: { self.sidebarBackground }, set: { self.setSidebar($0) })
    }
    var sidebarTextBinding: Binding<Color> {
        Binding(get: { self.sidebarText }, set: { self.setSidebarText($0) })
    }
    var plansCardBinding: Binding<Color> {
        Binding(get: { self.plansCard }, set: { self.setPlansCard($0) })
    }
    var plansPanelBinding: Binding<Color> {
        Binding(get: { self.plansPanel }, set: { self.setPlansPanel($0) })
    }
    var plansTextBinding: Binding<Color> {
        Binding(get: { self.plansCardText }, set: { self.setPlansText($0) })
    }
    var tasksPanelBinding: Binding<Color> {
        Binding(get: { self.tasksPanel }, set: { self.setTasksPanel($0) })
    }
    var tasksTextBinding: Binding<Color> {
        Binding(get: { self.tasksText }, set: { self.setTasksText($0) })
    }

    /// Two-way binding for a single panel kind's header color, for use
    /// directly in a `ColorPicker`. Reads/writes through `panelAccent(for:)`/
    /// `setPanelAccent(_:for:)`, so it always shows *some* concrete color
    /// (the shared accent until overridden) rather than needing an optional.
    func panelAccentBinding(for kind: WorkspacePanelKind) -> Binding<Color> {
        Binding(
            get: { self.panelAccent(for: kind) },
            set: { self.setPanelAccent($0, for: kind) })
    }

    func setAccent(_ color: Color) { accentOverride = color; persist(Self.accentKey, color) }
    func setUserBubble(_ color: Color) { userBubbleOverride = color; persist(Self.userBubbleKey, color) }
    func setUserBubbleText(_ color: Color) { userBubbleTextOverride = color; persist(Self.userBubbleTextKey, color) }
    func setChatBackground(_ color: Color) { chatBackgroundOverride = color; persist(Self.chatBackgroundKey, color) }
    func setChatText(_ color: Color) { chatTextOverride = color; persist(Self.chatTextKey, color) }
    func setChatSecondaryText(_ color: Color) { chatSecondaryTextOverride = color; persist(Self.chatSecondaryTextKey, color) }

    // MARK: - Luminance + contrast helpers

    static func grayColor(_ luminance: Double) -> Color {
        let clamped = min(max(luminance, 0), 1)
        return Color(nsColor: NSColor(calibratedWhite: clamped, alpha: 1))
    }

    static func relativeLuminance(of color: Color) -> Double {
        guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { return 0.5 }
        // Rec. 601 luma — plenty for a brightness dial.
        return Double(0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent)
    }

    /// Guaranteed-contrast text luminance for a given background luminance.
    static func contrastingTextLuminance(for background: Double) -> Double {
        background > 0.55 ? 0.10 : 0.90
    }

    /// Guaranteed-contrast text color for a given background color.
    static func contrastText(forBackground color: Color) -> Color {
        grayColor(contrastingTextLuminance(for: relativeLuminance(of: color)))
    }

    /// Secondary-strength text for chrome on theme-driven surfaces (captions,
    /// timestamps, picker labels, tool chips). Explicitly settable; otherwise
    /// derived from the effective chat text color so it always stays readable
    /// against the effective background — unlike system `.secondary`, which
    /// tracks only the app appearance.
    var chatSecondaryText: Color { chatSecondaryTextOverride ?? chatText.opacity(0.8) }

    // MARK: - Per-group resets (fall back to the adaptive defaults)

    func resetSidebarColors() {
        sidebarOverride = nil; sidebarTextOverride = nil
        UserDefaults.standard.removeObject(forKey: Self.sidebarKey)
        UserDefaults.standard.removeObject(forKey: Self.sidebarTextKey)
    }
    func resetPlansColors() {
        plansPanelOverride = nil; plansCardOverride = nil; plansTextOverride = nil
        UserDefaults.standard.removeObject(forKey: Self.plansPanelKey)
        UserDefaults.standard.removeObject(forKey: Self.plansCardKey)
        UserDefaults.standard.removeObject(forKey: Self.plansTextKey)
    }
    func resetChatColors() {
        chatBackgroundOverride = nil; chatTextOverride = nil; chatSecondaryTextOverride = nil
        UserDefaults.standard.removeObject(forKey: Self.chatBackgroundKey)
        UserDefaults.standard.removeObject(forKey: Self.chatTextKey)
        UserDefaults.standard.removeObject(forKey: Self.chatSecondaryTextKey)
    }
    func resetTasksColors() {
        tasksPanelOverride = nil; tasksTextOverride = nil
        UserDefaults.standard.removeObject(forKey: Self.tasksPanelKey)
        UserDefaults.standard.removeObject(forKey: Self.tasksTextKey)
    }
    func setSidebar(_ color: Color) { sidebarOverride = color; persist(Self.sidebarKey, color) }
    func setSidebarText(_ color: Color) { sidebarTextOverride = color; persist(Self.sidebarTextKey, color) }
    func setPlansPanel(_ color: Color) { plansPanelOverride = color; persist(Self.plansPanelKey, color) }
    func setPlansCard(_ color: Color) { plansCardOverride = color; persist(Self.plansCardKey, color) }
    func setPlansText(_ color: Color) { plansTextOverride = color; persist(Self.plansTextKey, color) }
    func setTasksPanel(_ color: Color) { tasksPanelOverride = color; persist(Self.tasksPanelKey, color) }
    func setTasksText(_ color: Color) { tasksTextOverride = color; persist(Self.tasksTextKey, color) }
    func setBackground(_ color: Color) { backgroundOverride = color; persist(Self.backgroundKey, color) }
    func setSecondaryBackground(_ color: Color) { secondaryBackgroundOverride = color; persist(Self.secondaryBackgroundKey, color) }

    /// Set (or clear, by passing `nil`) a single panel kind's color override.
    func setPanelAccent(_ color: Color?, for kind: WorkspacePanelKind) {
        panelAccentOverrides[kind.themeStorageKey] = color
        persistPanelAccents()
    }

    private func persistPanelAccents() {
        let hexByKey = panelAccentOverrides.compactMapValues(\.hexRGBA)
        if let data = try? JSONEncoder().encode(hexByKey) {
            UserDefaults.standard.set(data, forKey: Self.panelAccentsKey)
        }
    }

    /// Clear all color overrides (back to the system accent / white text).
    func resetColors() {
        accentOverride = nil
        userBubbleOverride = nil
        userBubbleTextOverride = nil
        chatBackgroundOverride = nil
        chatTextOverride = nil
        chatSecondaryTextOverride = nil
        sidebarOverride = nil
        sidebarTextOverride = nil
        plansPanelOverride = nil
        plansCardOverride = nil
        plansTextOverride = nil
        tasksPanelOverride = nil
        tasksTextOverride = nil
        backgroundOverride = nil
        secondaryBackgroundOverride = nil
        panelAccentOverrides = [:]
        for key in [
            Self.accentKey, Self.userBubbleKey, Self.userBubbleTextKey,
            Self.chatBackgroundKey, Self.chatTextKey, Self.chatSecondaryTextKey, Self.sidebarKey, Self.sidebarTextKey,
            Self.plansPanelKey, Self.plansCardKey, Self.plansTextKey, Self.tasksPanelKey, Self.tasksTextKey,
            Self.backgroundKey, Self.secondaryBackgroundKey, Self.panelAccentsKey,
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
    /// Parse a 6-digit `RRGGBB` or 8-digit `RRGGBBAA` hex string (leading `#` optional).
    init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        if string.count == 8, let value = UInt64(string, radix: 16) {
            self = Color(
                .sRGB,
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                opacity: Double(value & 0xFF) / 255)
        } else if string.count == 6, let value = UInt64(string, radix: 16) {
            self = Color(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: 1.0)
        } else {
            return nil
        }
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
