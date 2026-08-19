import SwiftUI

// MARK: - App Category
//
// The launcher groups its apps into three user-facing categories. This enum is
// the single source of truth for which apps belong to which category and in
// what display order, so `AppsLauncherPanel` and the Settings → Apps tab stay
// in sync. Plugins are intentionally NOT a category here — they're data-driven
// and always shown when present.

enum AppCategory: String, CaseIterable, Codable, Sendable {
    case appleApps
    case studio
    case swiftApps

    /// Section title shown in the launcher and in Settings.
    var title: String {
        switch self {
        case .appleApps: return "Apple Apps"
        case .studio: return "Studio"
        case .swiftApps: return "Swift Apps"
        }
    }

    /// Whether this category is completely hidden from the UI (launcher,
    /// Settings, and everywhere else). Hidden categories still exist in the
    /// enum for type-safety but are invisible to users. Set this to `false`
    /// when the feature is ready to ship.
    var isHidden: Bool {
        switch self {
        case .studio: return true          // Not ready — hide entirely
        case .appleApps, .swiftApps: return false
        }
    }

    /// The apps in this category, in launcher display order.
    var kinds: [WorkspacePanelKind] {
        switch self {
        case .appleApps:
            return [.appleNotes, .calendar, .reminders, .contacts, .numbers, .maps, .photos, .mail]
        case .studio:
            return []                      // Hidden — no apps exposed
        case .swiftApps:
            // Bus Monitor is deliberately NOT listed: it's agent-infrastructure
            // debugging, not a user app. The panel kind still works — agents can
            // open it with open_panel("bus") when diagnosing bus traffic.
            return [.audioControl, .notesMD, .voiceNotes, .canvas, .kanban, .terminal, .webBrowser, .stocks, .damBrowser, .maestroDocs, .maestroBooks, .maestroDB, .htmlBuilder, .backup]
        }
    }

    /// Built-in native panels that live in the launcher under **Plugins**
    /// alongside the manifest-driven WKWebView plugins (Bluesky, Mastodon,
    /// Patreon). They're not plugins technically — they're grouped there
    /// because they're the same kind of thing to the user (social/account
    /// panels) — and they share the plugins' enablement toggles, keyed by
    /// `themeStorageKey` in the same `disabledPlugins` set.
    static let builtInPluginKinds: [WorkspacePanelKind] = [.whatsapp, .discord]
}

extension WorkspacePanelKind {
    /// The launcher category this panel belongs to, or `nil` for non-launcher
    /// chrome (agents, appLauncher, agentChat, plugin) and for the built-in
    /// plugin-section panels (whatsapp/discord — toggled as plugins instead).
    var appCategory: AppCategory? {
        switch self {
        case .appleNotes, .calendar, .reminders, .contacts, .numbers, .maps, .photos, .mail:
            return .appleApps
        case .tethering, .streamIngest, .broadcast, .streamMixer, .ndiBrowser, .colorAdjustments, .scenes:
            return .studio
        case .audioControl, .notesMD, .voiceNotes, .canvas, .kanban, .terminal, .webBrowser, .stocks, .damBrowser, .maestroDocs, .maestroBooks, .maestroDB, .htmlBuilder, .backup:
            return .swiftApps
        default:
            return nil
        }
    }
}

// MARK: - App Enablement Store
//
// Tracks which launcher apps and categories the user has chosen to show.
// Everything defaults to ENABLED so existing users see no change; disabling a
// category or app simply hides its row in the Apps launcher. Persisted to
// UserDefaults so the choice survives relaunches.
//
// Scope note: this gates launcher VISIBILITY only. It does not close an
// already-open panel, and it does not disable the agent's tools for that app —
// tool availability is governed separately (Rules / MCP settings).
@Observable
@MainActor
final class AppEnablementStore {
    static let shared = AppEnablementStore()

    private static let disabledAppsKey = "settings.apps.disabledApps"
    private static let disabledCategoriesKey = "settings.apps.disabledCategories"
    private static let pluginsSectionEnabledKey = "settings.apps.pluginsSectionEnabled"
    private static let disabledPluginsKey = "settings.apps.disabledPlugins"

    /// `themeStorageKey`s of individually disabled apps. Empty = all enabled.
    private(set) var disabledApps: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledApps), forKey: Self.disabledAppsKey) }
    }

    /// Raw values of disabled categories. Empty = all enabled.
    private(set) var disabledCategories: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledCategories), forKey: Self.disabledCategoriesKey) }
    }

    /// Whether the Plugins section as a whole is shown. Default true.
    var pluginsSectionEnabled: Bool {
        didSet { UserDefaults.standard.set(pluginsSectionEnabled, forKey: Self.pluginsSectionEnabledKey) }
    }

    /// Plugin manifest ids of individually disabled plugins. Empty = all enabled.
    private(set) var disabledPlugins: Set<String> {
        didSet { UserDefaults.standard.set(Array(disabledPlugins), forKey: Self.disabledPluginsKey) }
    }

    private init() {
        disabledApps = Set(UserDefaults.standard.stringArray(forKey: Self.disabledAppsKey) ?? [])
        disabledCategories = Set(UserDefaults.standard.stringArray(forKey: Self.disabledCategoriesKey) ?? [])
        pluginsSectionEnabled = UserDefaults.standard.object(forKey: Self.pluginsSectionEnabledKey) as? Bool ?? true
        disabledPlugins = Set(UserDefaults.standard.stringArray(forKey: Self.disabledPluginsKey) ?? [])
    }

    // MARK: - Queries

    /// Whether a category's section is enabled (its master toggle).
    func isCategoryEnabled(_ category: AppCategory) -> Bool {
        !disabledCategories.contains(category.rawValue)
    }

    /// Whether an individual app's own toggle is on, independent of its
    /// category. Backs the per-app switch in Settings.
    func isAppEnabled(_ kind: WorkspacePanelKind) -> Bool {
        !disabledApps.contains(kind.themeStorageKey)
    }

    /// Whether an app's row should actually appear in the launcher — its
    /// category must be enabled AND the app itself must not be disabled.
    /// Non-launcher panels (no category) are always shown.
    func showsApp(_ kind: WorkspacePanelKind) -> Bool {
        guard let category = kind.appCategory else { return true }
        return isCategoryEnabled(category) && isAppEnabled(kind)
    }

    /// The apps of a category that should appear in the launcher right now.
    func visibleKinds(in category: AppCategory) -> [WorkspacePanelKind] {
        category.kinds.filter { showsApp($0) }
    }

    /// Whether an individual plugin's own toggle is on (independent of the
    /// Plugins section master switch).
    func isPluginEnabled(_ id: String) -> Bool {
        !disabledPlugins.contains(id)
    }

    /// Whether a plugin's row should appear in the launcher — the Plugins
    /// section must be enabled AND the plugin itself must not be disabled.
    func showsPlugin(_ id: String) -> Bool {
        pluginsSectionEnabled && isPluginEnabled(id)
    }

    /// Whether a built-in plugin-section panel (whatsapp/discord) should
    /// appear in the launcher — same rule as manifest plugins, keyed by
    /// `themeStorageKey` so Settings can show a friendly per-app toggle.
    func showsBuiltInPlugin(_ kind: WorkspacePanelKind) -> Bool {
        pluginsSectionEnabled && isPluginEnabled(kind.themeStorageKey)
    }

    // MARK: - Mutations

    func setCategory(_ category: AppCategory, enabled: Bool) {
        if enabled {
            disabledCategories.remove(category.rawValue)
        } else {
            disabledCategories.insert(category.rawValue)
        }
    }

    func setApp(_ kind: WorkspacePanelKind, enabled: Bool) {
        if enabled {
            disabledApps.remove(kind.themeStorageKey)
        } else {
            disabledApps.insert(kind.themeStorageKey)
        }
    }

    func setPlugin(_ id: String, enabled: Bool) {
        if enabled {
            disabledPlugins.remove(id)
        } else {
            disabledPlugins.insert(id)
        }
    }

    /// Convenience: enable every category, app, and plugin (restore defaults).
    func enableAll() {
        disabledCategories = []
        disabledApps = []
        disabledPlugins = []
        pluginsSectionEnabled = true
    }

    // MARK: - Bindings

    func categoryBinding(for category: AppCategory) -> Binding<Bool> {
        Binding(
            get: { self.isCategoryEnabled(category) },
            set: { self.setCategory(category, enabled: $0) }
        )
    }

    func appBinding(for kind: WorkspacePanelKind) -> Binding<Bool> {
        Binding(
            get: { self.isAppEnabled(kind) },
            set: { self.setApp(kind, enabled: $0) }
        )
    }

    func pluginsSectionBinding() -> Binding<Bool> {
        Binding(
            get: { self.pluginsSectionEnabled },
            set: { self.pluginsSectionEnabled = $0 }
        )
    }

    func pluginBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.isPluginEnabled(id) },
            set: { self.setPlugin(id, enabled: $0) }
        )
    }
}
