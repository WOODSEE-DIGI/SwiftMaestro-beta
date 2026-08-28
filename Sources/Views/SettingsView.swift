import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SwiftMaestroSettingsStore {
    static let allowedModelsKey = "settings.models.allowedModels"
    static let authorizedFoldersKey = "settings.context.authorizedFolders"
    static let filesInMemoryKey = "settings.context.filesInMemory"
    static let lastImportDateKey = "settings.context.lastImportDate"
    static let mcpServersKey = "settings.mcp.servers"
    static let mcpCustomPresetKey = "settings.mcp.preset.custom"
    static let mcpBundledPresetVersionKey = "settings.mcp.preset.bundledVersion"
    static let agentRulesKey = "settings.rules.agentRules"
    static let collapseCompactionSummariesKey = "settings.compaction.collapseSummariesByDefault"
    static let fullDiskAccessKey = "settings.context.fullDiskAccess"

    static func loadAllowedModels() -> [String] {
        UserDefaults.standard.stringArray(forKey: allowedModelsKey) ?? []
    }

    static func saveAllowedModels(_ models: [String]) {
        UserDefaults.standard.set(models, forKey: allowedModelsKey)
    }

    static func loadAuthorizedFolders() -> [AuthorizedFolder] {
        let home = NSHomeDirectory()
        let defaults: [AuthorizedFolder] = [
            AuthorizedFolder(path: SwiftMaestroPaths.appSupportDir.path, enabled: true),
            AuthorizedFolder(path: home + "/.ai-context", enabled: true),
            AuthorizedFolder(path: home + "/Documents", enabled: true),
            AuthorizedFolder(path: home + "/Obsidian", enabled: true),
            // Scratch space for agent build/test artifacts (e.g. "create a file in
            // /tmp"). World-writable but standard practice for throwaway work.
            AuthorizedFolder(path: "/tmp", enabled: true),
        ]

        guard
            let data = UserDefaults.standard.data(forKey: authorizedFoldersKey),
            let savedFolders = try? JSONDecoder().decode([AuthorizedFolder].self, from: data)
        else {
            return defaults
        }

        // Merge must-always-be-authorized folders into the saved list. The app
        // must always be able to read its own logs/data/backups, and agents
        // always need a scratch directory (/tmp) for build/test artifacts —
        // both are added automatically if the user removed them or created the
        // list before they were defaults.
        var merged = savedFolders
        var didChange = false
        let appSupportPath = SwiftMaestroPaths.appSupportDir.path
        if !merged.contains(where: { $0.path == appSupportPath }) {
            merged.insert(AuthorizedFolder(path: appSupportPath, enabled: true), at: 0)
            didChange = true
        }
        if !merged.contains(where: { $0.path == "/tmp" }) {
            merged.append(AuthorizedFolder(path: "/tmp", enabled: true))
            didChange = true
        }
        if didChange {
            saveAuthorizedFolders(merged)
        }
        return merged
    }

    static func saveAuthorizedFolders(_ folders: [AuthorizedFolder]) {
        if let data = try? JSONEncoder().encode(folders) {
            UserDefaults.standard.set(data, forKey: authorizedFoldersKey)
        }
    }

    static func loadFilesInMemory() -> Int {
        UserDefaults.standard.integer(forKey: filesInMemoryKey)
    }

    static func saveFilesInMemory(_ count: Int) {
        UserDefaults.standard.set(count, forKey: filesInMemoryKey)
    }

    static func loadFullDiskAccess() -> Bool {
        UserDefaults.standard.bool(forKey: fullDiskAccessKey)
    }

    static func saveFullDiskAccess(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: fullDiskAccessKey)
    }

    static func loadLastImportDate() -> String {
        UserDefaults.standard.string(forKey: lastImportDateKey) ?? ""
    }

    static func saveLastImportDate(_ value: String) {
        UserDefaults.standard.set(value, forKey: lastImportDateKey)
    }

    static func loadMCPServers() -> [MCPServerEntry] {
        guard
            let data = UserDefaults.standard.data(forKey: mcpServersKey),
            let servers = try? JSONDecoder().decode([MCPServerEntry].self, from: data)
        else {
            return MCPServerEntry.defaults
        }
        return servers
    }

    static func saveMCPServers(_ servers: [MCPServerEntry]) {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: mcpServersKey)
        }
    }

    /// Save the current MCP server list as the user's custom preset.
    static func saveCustomMCPPreset(_ servers: [MCPServerEntry]) {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: mcpCustomPresetKey)
        }
    }

    /// Load the user's custom preset, or nil if none has been saved.
    static func loadCustomMCPPreset() -> [MCPServerEntry]? {
        guard let data = UserDefaults.standard.data(forKey: mcpCustomPresetKey) else { return nil }
        return try? JSONDecoder().decode([MCPServerEntry].self, from: data)
    }

    /// Remove the custom preset.
    static func clearCustomMCPPreset() {
        UserDefaults.standard.removeObject(forKey: mcpCustomPresetKey)
    }

    static func loadRules() -> [AgentRule] {
        guard
            let data = UserDefaults.standard.data(forKey: agentRulesKey),
            let rules = try? JSONDecoder().decode([AgentRule].self, from: data)
        else {
            return AgentRule.defaults
        }
        return rules
    }

    static func saveRules(_ rules: [AgentRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: agentRulesKey)
        }
    }

    static func loadCollapseCompactionSummaries() -> Bool {
        UserDefaults.standard.object(forKey: collapseCompactionSummariesKey) as? Bool ?? false
    }

    static func saveCollapseCompactionSummaries(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: collapseCompactionSummariesKey)
    }
}

// MARK: - Settings tab strip

/// The Settings window's tabs. A plain `TabView`'s macOS toolbar strip clips
/// once the tab count outgrows the window width, so this is a custom strip:
/// a wrapping grid that flows onto a second (and third) row instead. Order
/// here is the strip's left-to-right, top-to-bottom order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case models
    case tuning
    case visionProxy
    case appearance
    case apps
    case mail
    case rules
    case context
    case clipper
    case mcp
    case storage
    case secrets
    case whisper
    case shell
    case healing
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .models: return String(localized: "Models")
        case .tuning: return String(localized: "Tuning")
        case .visionProxy: return String(localized: "Vision Proxy")
        case .appearance: return String(localized: "Appearance")
        case .apps: return String(localized: "Apps")
        case .mail: return String(localized: "Mail")
        case .rules: return String(localized: "Rules")
        case .context: return String(localized: "Context")
        case .clipper: return String(localized: "Clipper")
        case .mcp: return String(localized: "MCP")
        case .storage: return String(localized: "Storage")
        case .secrets: return String(localized: "Secrets")
        case .whisper: return String(localized: "Whisper")
        case .shell: return String(localized: "Shell")
        case .healing: return String(localized: "Self-Healing")
        case .about: return String(localized: "About")
        }
    }

    var icon: String {
        switch self {
        case .models: return "cpu"
        case .tuning: return "slider.horizontal.3"
        case .visionProxy: return "eye"
        case .appearance: return "paintpalette"
        case .apps: return "square.grid.2x2"
        case .mail: return "envelope"
        case .rules: return "list.bullet.rectangle"
        case .context: return "folder"
        case .clipper: return "scissors"
        case .mcp: return "server.rack"
        case .storage: return "externaldrive"
        case .secrets: return "key.fill"
        case .whisper: return "mic.fill"
        case .shell: return "terminal"
        case .healing: return "bandage"
        case .about: return "info.circle"
        }
    }
}

/// Wrapping icon grid backing the Settings window's tab strip. Selected tab
/// gets an accent wash; the grid wraps to additional rows automatically as
/// the tab count grows.
private struct SettingsTabStrip: View {
    @Environment(ThemeStore.self) private var theme
    @Binding var selection: SettingsTab

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 4)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                let isSelected = selection == tab
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.title3)
                            .frame(height: 22)
                        Text(tab.title)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        isSelected ? theme.accent.opacity(0.22) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? theme.accent.opacity(0.6) : Color.clear))
                    .foregroundStyle(isSelected ? theme.accent : theme.chatText.opacity(0.75))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(VisionProxyService.self) private var visionProxy
    @Environment(ThemeStore.self) private var theme

    @AppStorage("settings.selectedTab") private var selectedTab: SettingsTab = .models

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabStrip(selection: $selectedTab)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            tabContent
        }
        // Grow to fill whatever size the user resizes the window to (maxWidth/
        // maxHeight: .infinity), while keeping a sensible minimum so controls stay
        // usable. The window itself is resizable via `.windowResizability` on the
        // Settings scene.
        .frame(
            minWidth: 760, idealWidth: 900, maxWidth: .infinity,
            minHeight: 780, idealHeight: 960, maxHeight: .infinity)
        .tint(theme.accent)
        .foregroundStyle(theme.chatText)
        .preferredColorScheme(theme.appearance.colorScheme)
        #if os(macOS)
        .background(
            WindowSizeConfigurator(
                minSize: CGSize(width: 760, height: 780),
                defaultSize: CGSize(width: 900, height: 960),
                backgroundColor: theme.background
            )
        )
        #endif
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .models: ModelsSettingsTab()
        case .tuning: TuningSettingsTab()
        case .visionProxy: VisionProxySettingsTab()
        case .appearance: AppearanceSettingsTab()
        case .apps: AppsSettingsTab()
        case .mail: MailSettingsTab()
        case .rules: RulesSettingsTab()
        case .context: ContextSettingsTab()
        case .clipper: ClipperSettingsTab()
        case .mcp: MCPSettingsTab()
        case .storage: StorageSettingsTab()
        case .secrets: SecretsSettingsTab()
        case .whisper: WhisperKitSettingsTab()
        case .shell: ShellSettingsTab()
        case .healing: SelfHealingSettingsTab()
        case .about: AboutSettingsTab()
        }
    }
}

// MARK: - Appearance tab (theme colors + light/dark)

/// Lets the user tailor UI colors (accent + chat bubble) and force light/dark.
/// Changes apply live app-wide via `ThemeStore` and persist across launches.
/// Card-like chrome for a top-level `DisclosureGroup` section in the
/// Appearance tab: padding, a subtle background, and a rounded border — so
/// collapsed/expanded sections still read as distinct blocks the way the
/// previous `GroupBox`-based layout did.
private struct AppearanceSectionStyle: ViewModifier {
    @Environment(ThemeStore.self) private var theme

    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15)))
    }
}

private extension View {
    /// Applies `AppearanceSectionStyle`. Used on every collapsible section in
    /// `AppearanceSettingsTab` so `DisclosureGroup`s (which have no built-in
    /// card chrome the way `GroupBox` does) still look like distinct blocks.
    func appearanceSectionStyle() -> some View {
        modifier(AppearanceSectionStyle())
    }
}

struct AppearanceSettingsTab: View {
    @Environment(ThemeStore.self) private var theme
    @Environment(SkinStore.self) private var skinStore

    @State private var showingImportSkinPanel = false
    @State private var showingExportSkinPanel = false
    @State private var showingSaveSkinSheet = false
    @State private var skinToExport: Skin?
    @State private var newSkinName = ""
    @State private var newSkinDescription = ""

    /// Panel kinds that get their own customizable header color. Excludes
    /// `.agentChat` (already covered by the "Chat" section's colors) and
    /// `.plugin` (data-driven, unbounded count — plugin panels just follow
    /// the shared accent for now).
    static let customizablePanels: [WorkspacePanelKind] = [
        .busMonitor, .notesMD, .appleNotes, .calendar, .reminders, .contacts,
        .canvas, .kanban, .numbers, .whatsapp, .terminal,
        .webBrowser, .damBrowser, .maestroDocs, .maestroBooks, .maestroDB, .htmlBuilder, .backup, .voiceNotes,
        .pomodoro,
    ]

    // Collapsible section state. "Language" and "Appearance" open by
    // default (most commonly touched); the rest start collapsed so the tab
    // fits on one screen instead of requiring a long scroll.
    @State private var languageExpanded = true
    @State private var appearanceExpanded = true
    @State private var sidebarExpanded = false
    @State private var plansExpanded = false
    @State private var chatExpanded = false
    @State private var tasksExpanded = false
    @State private var panelsExpanded = true
    @State private var previewExpanded = false

    /// The 10 languages fully translated for v0.4.0.
    static let supportedLanguages: [(code: String, name: String)] = [
        ("de", "Deutsch"),
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("it", "Italiano"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("pt-BR", "Português (Brasil)"),
        ("ru", "Русский"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
    ]

    /// Persisted language code. Empty string = system default.
    @AppStorage("settings.appearance.language") private var selectedLanguage = ""

    private func applyLanguage(_ code: String) {
        if code.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        }
        // AppleLanguages is read by Bundle.main at launch — a relaunch is needed
        // for the change to fully take effect across all panels.
    }

    var body: some View {
        @Bindable var theme = theme
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Language picker — sits above Appearance so it's the first thing
                // a new user sees when they open the app in a non-English locale.
                DisclosureGroup("Language", isExpanded: $languageExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("App language", selection: $selectedLanguage) {
                            Text("System Default").tag("")
                            ForEach(Self.supportedLanguages, id: \.code) { lang in
                                Text("\(lang.name) (\(lang.code))").tag(lang.code)
                            }
                        }
                        .onChange(of: selectedLanguage) { _, new in
                            applyLanguage(new)
                        }
                        Text("Relaunch SwiftMaestro after changing to fully apply all translations.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
                .appearanceSectionStyle()

                // Global appearance: window light/dark plus the accent that tints
                // buttons, selections, and plan cards across the whole app.
                DisclosureGroup("Appearance", isExpanded: $appearanceExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Mode", selection: Binding(
                            get: { skinStore.skinModeEnabled },
                            set: { skinStore.skinModeEnabled = $0 }
                        )) {
                            Text("System").tag(false)
                            Text("Skin").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text(skinStore.skinModeEnabled
                            ? "Skin mode: pick one skin below — it sets everything, including the appearance."
                            : "System mode: the System Default theme, with your choice of light/dark.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Picker("Theme", selection: $theme.appearance) {
                            ForEach(ThemeStore.Appearance.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(skinStore.skinModeEnabled)
                        .opacity(skinStore.skinModeEnabled ? 0.45 : 1)
                        Text(skinStore.skinModeEnabled
                            ? "Appearance is driven by the selected skin."
                            : "Force light or dark, or follow the system setting.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        ColorPicker("Accent color", selection: theme.accentBinding, supportsOpacity: false)
                        Text("Tints buttons, selections, links, and plan cards app-wide. Also the "
                            + "default header color for any panel below that hasn't been customized.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Surfaces and their text/icons follow the selected theme automatically — "
                            + "text is always contrast-computed against its own background, so "
                            + "everything stays legible. Fine-tune individual panels in the groups below.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        skinSection
                    }
                    .padding(.top, 8)
                }
                .appearanceSectionStyle()

                // Panel-by-panel colors, ordered to match the window left-to-right:
                // sidebar, then the Plans panel, the chat in the middle, then Tasks.
                // Each panel groups its background with its text color.
                DisclosureGroup("Sidebar", isExpanded: $sidebarExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ColorPicker("Background", selection: theme.sidebarBinding, supportsOpacity: false)
                        ColorPicker("Text", selection: theme.sidebarTextBinding, supportsOpacity: false)
                        Text("Agent list on the left. Leave the background unset to follow the system.")
                            .font(.caption).foregroundStyle(.secondary)
                        ResetToGlobalButton(action: theme.resetSidebarColors)
                    }
                    .padding(.top, 8)
                }
                .appearanceSectionStyle()

                DisclosureGroup("Plans panel", isExpanded: $plansExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ColorPicker("Background", selection: theme.plansPanelBinding, supportsOpacity: false)
                        ColorPicker("Card bubble", selection: theme.plansCardBinding, supportsOpacity: false)
                        ColorPicker("Card text", selection: theme.plansTextBinding, supportsOpacity: false)
                        Text("Cards default to the accent color; card text always contrasts against the card.")
                            .font(.caption).foregroundStyle(.secondary)
                        ResetToGlobalButton(action: theme.resetPlansColors)
                    }
                    .padding(.top, 8)
                }
                .appearanceSectionStyle()

                DisclosureGroup("Chat", isExpanded: $chatExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ColorPicker("Background", selection: theme.chatBackgroundBinding, supportsOpacity: false)
                        ColorPicker("Assistant text", selection: theme.chatTextBinding, supportsOpacity: false)
                        ColorPicker("Secondary text (chips, timestamps)", selection: theme.chatSecondaryTextBinding, supportsOpacity: false)
                        ColorPicker("Your message bubble", selection: theme.userBubbleBinding, supportsOpacity: false)
                        ColorPicker("Your message text", selection: theme.userBubbleTextBinding, supportsOpacity: false)
                        Text("Leave the background unset to follow the system.")
                            .font(.caption).foregroundStyle(.secondary)
                        ResetToGlobalButton(action: theme.resetChatColors)
                    }
                    .padding(.top, 8)
                }
                .appearanceSectionStyle()

                DisclosureGroup("Tasks panel", isExpanded: $tasksExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ColorPicker("Background", selection: theme.tasksPanelBinding, supportsOpacity: false)
                        ColorPicker("Text", selection: theme.tasksTextBinding, supportsOpacity: false)
                        ResetToGlobalButton(action: theme.resetTasksColors)
                    }
                    .padding(.top, 8)
                }
                .appearanceSectionStyle()

                // Per-panel header colors for every "app panel" (Calendar,
                // Reminders, Contacts, ...), docked or floating — both use the
                // same ThemeStore.panelAccent(for:) lookup.
                DisclosureGroup("App Panels", isExpanded: $panelsExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Each panel's header tint. Defaults to the accent color above until "
                            + "you pick one here.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(Self.customizablePanels, id: \.self) { kind in
                            panelColorRow(for: kind)
                        }
                    }
                    .padding(.top, 8)
                }
                .appearanceSectionStyle()

                DisclosureGroup("Preview", isExpanded: $previewExpanded) {
                    preview.padding(.top, 8)
                }
                .appearanceSectionStyle()

                HStack {
                    Spacer()
                    Button("Reset to defaults") { theme.resetColors() }
                        .disabled(!theme.hasColorOverrides)
                }
                Spacer()
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            // The shared color panel otherwise opens on the grayscale slider for
            // white/clear/gray starting colors (so it looks "black" until you
            // click a colored swatch). Force the color wheel and hide the alpha
            // slider to match our opaque pickers.
            NSColorPanel.shared.mode = .wheel
            NSColorPanel.shared.showsAlpha = false
        }
    }

    private func panelColorRow(for kind: WorkspacePanelKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .frame(width: 18)
                .foregroundStyle(theme.panelAccent(for: kind))
            Text(kind.staticDisplayName ?? kind.themeStorageKey)
                .font(.callout)
            Spacer()
            ColorPicker("", selection: theme.panelAccentBinding(for: kind), supportsOpacity: false)
                .labelsHidden()
            if theme.panelAccentOverride(for: kind) != nil {
                Button {
                    theme.setPanelAccent(nil, for: kind)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reset \(kind.staticDisplayName ?? "this panel") to the accent color")
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer(minLength: 40)
                    Text("How do I tune sampling?")
                        .foregroundStyle(theme.userBubbleText)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            theme.userBubble,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Text("An assistant reply looks like this.")
                Button("Accent button") {}
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.chatBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.2)))

            HStack(spacing: 10) {
                swatch("Sidebar", theme.sidebarBackground)
                swatch("Plans", theme.plansPanel)
                swatch("Tasks", theme.tasksPanel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.25)))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Skin Section

    private var skinSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skin")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            Picker("Skin", selection: Binding(
                get: { skinStore.skinModeEnabled ? (skinStore.currentSkinID ?? Skin.default.id) : Skin.default.id },
                set: { skinStore.applySkin(id: $0) }
            )) {
                ForEach(skinStore.skins) { skin in
                    Text(skin.name)
                        .tag(skin.id)
                        .help(skin.description ?? "")
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .foregroundStyle(theme.chatText)
            .disabled(!skinStore.skinModeEnabled)
            .opacity(skinStore.skinModeEnabled ? 1 : 0.45)

            Text(skinStore.skinModeEnabled
                ? (skinStore.currentSkin?.description ?? "Choose a preset, or save and import custom skins.")
                : "Locked to System Default in System mode. Switch to Skin mode to choose a skin.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Import skin…") { showingImportSkinPanel = true }
                Button("Export current skin…") {
                    skinToExport = skinStore.skinFromCurrentColors(name: "My Skin")
                    showingExportSkinPanel = true
                }
                .disabled(!theme.hasColorOverrides && skinStore.currentSkin == nil)
                Button("Save current as skin…") { showingSaveSkinSheet = true }
                .disabled(!theme.hasColorOverrides && skinStore.currentSkin == nil)
            }
            .controlSize(.small)

            if let currentSkin = skinStore.currentSkin, !currentSkin.isBuiltIn {
                HStack(spacing: 8) {
                    Button("Delete \"\(currentSkin.name)\"", role: .destructive) {
                        do {
                            try skinStore.deleteSkin(currentSkin)
                        } catch {
                            NSLog("[SkinStore] delete failed: \(error)")
                        }
                    }
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
        .fileImporter(
            isPresented: $showingImportSkinPanel,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try skinStore.importSkin(from: url)
                } catch {
                    NSLog("[SkinStore] import failed: \(error)")
                }
            case .failure:
                break
            }
        }
        .fileExporter(
            isPresented: $showingExportSkinPanel,
            document: skinToExport.map { SkinDocument(skin: $0) },
            contentType: .json,
            defaultFilename: "My Skin"
        ) { result in
            if case .failure(let error) = result {
                NSLog("[SkinStore] export failed: \(error)")
            }
        }
        .sheet(isPresented: $showingSaveSkinSheet) {
            SaveSkinSheet(
                skinStore: skinStore,
                isPresented: $showingSaveSkinSheet,
                name: $newSkinName,
                description: $newSkinDescription
            )
        }
    }
}

// MARK: - Skin Save Sheet

private struct SaveSkinSheet: View {
    let skinStore: SkinStore
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save current colors as skin")
                .font(.headline)
            TextField("Skin name", text: $name)
            TextField("Description (optional)", text: $description)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                Button("Save") {
                    guard !name.isEmpty else { return }
                    let skin = skinStore.skinFromCurrentColors(
                        name: name,
                        description: description.isEmpty ? nil : description
                    )
                    do {
                        try skinStore.saveSkin(skin)
                        skinStore.applySkin(skin)
                    } catch {
                        NSLog("[SkinStore] save failed: \(error)")
                    }
                    isPresented = false
                    name = ""
                    description = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

// MARK: - Skin Export Document

private struct SkinDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var skin: Skin

    init(skin: Skin) { self.skin = skin }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.skin = try Skin.from(jsonData: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try skin.jsonData())
    }
}

// MARK: - Storage tab (Plans & Todos)

/// Shows where the live Todo checklists and Plan documents are stored on disk,
/// with quick access to reveal them in Finder.
struct StorageSettingsTab: View {
    @State private var todoCount = 0
    @State private var planCount = 0

    private var root: URL { WorkspaceStore.appSupportDir() }
    private var dataDir: URL { WorkspaceStore.dataDir() }
    private var modelsDir: URL { URL(fileURLWithPath: ModelCatalog.modelsRoot) }
    private var logsDir: URL { SwiftMaestroPaths.logsDir }
    private var todosDir: URL { dataDir.appendingPathComponent("todos", isDirectory: true) }
    private var plansDir: URL { dataDir.appendingPathComponent("plans", isDirectory: true) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Storage Locations") {
                    VStack(alignment: .leading, spacing: 12) {
                        locationRow("App root", root,
                            subtitle: "All SwiftMaestro data, models, logs, and backups")
                        Divider()
                        locationRow("Models", modelsDir,
                            subtitle: "MLX model files — override in Settings → Models")
                        Divider()
                        locationRow("Todos", todosDir,
                            subtitle: "\(todoCount) checklist file(s) — one JSON per agent")
                        Divider()
                        locationRow("Plans", plansDir,
                            subtitle: "\(planCount) scope file(s) — per agent + per project, each plan also mirrored as .md")
                        Divider()
                        locationRow("Logs", logsDir,
                            subtitle: "Background process output and download logs")
                    }
                    .padding(8)
                }
                GroupBox("About") {
                    Text("SwiftMaestro keeps everything in one app root under Application Support. "
                        + "Shared memory still lives in ~/.ai-context/memory/ so Qwen Code and other tools can read it.")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
                Spacer()
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func locationRow(_ title: String, _ url: URL, subtitle: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.bold())
                Text(url.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal in Finder") {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .font(.caption)
        }
    }

    private func refresh() {
        todoCount = jsonCount(todosDir)
        planCount = jsonCount(plansDir)
    }

    private func jsonCount(_ dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }.count ?? 0
    }
}

// MARK: - Secrets tab

struct SecretsSettingsTab: View {
    @State private var secrets: [SecretMetadata] = []
    @State private var showingAdd = false
    @State private var editingMeta: SecretMetadata? = nil
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Stored Secrets") {
                    VStack(alignment: .leading, spacing: 10) {
                        if secrets.isEmpty {
                            Text("No secrets stored yet. Add a token below; the agent references it by name and never sees the raw value.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(secrets) { meta in
                            HStack(alignment: .top) {
                                Image(systemName: "key.fill").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meta.name).font(.body.bold())
                                    HStack(spacing: 8) {
                                        scopeBadge(meta)
                                        if meta.synced {
                                            Label("iCloud", systemImage: "icloud")
                                                .font(.caption2).foregroundStyle(.blue)
                                        }
                                        Text("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let used = meta.lastUsedAt {
                                        Text("last used \(used.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button { editingMeta = meta } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) { delete(meta) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }
                            Divider()
                        }
                        let projects = Set(secrets.compactMap { $0.projectId }).sorted()
                        if !projects.isEmpty {
                            ForEach(projects, id: \.self) { pid in
                                HStack {
                                    Text("Project scope: \(pid)").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Purge project secrets", role: .destructive) { purge(pid) }
                                        .font(.caption)
                                }
                            }
                        }
                        HStack {
                            Button("Add Secret") { showingAdd = true }
                            Spacer()
                            if let errorMessage {
                                Text(errorMessage).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(8)
                }
                GroupBox("How secrets are used") {
                    Text("Reference a secret anywhere a token is needed as secret://<name>. SwiftMaestro and sibling agents (via ai-context-bridge) resolve it from the Keychain at the moment of the request \u{2014} the value is never written to chat history, logs, or the shared memory store.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(8)
                }
                Spacer()
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .onAppear { reload() }
        .sheet(isPresented: $showingAdd) {
            AddSecretSheet { name, value, scope, synced, note in
                add(name: name, value: value, scope: scope, synced: synced, note: note)
            }
        }
        .sheet(item: $editingMeta) { meta in
            EditSecretSheet(meta: meta) { name, value, scope, synced, note in
                edit(original: meta, name: name, value: value, scope: scope, synced: synced, note: note)
            }
        }
    }

    @ViewBuilder
    private func scopeBadge(_ meta: SecretMetadata) -> some View {
        switch meta.scope {
        case .global:
            Label("Permanent", systemImage: "globe").font(.caption2).foregroundStyle(.green)
        case .project(let id):
            Label("Project: \(id)", systemImage: "folder").font(.caption2).foregroundStyle(.purple)
        }
    }

    private func reload() {
        secrets = SecretsStore.listMetadata().sorted { $0.name < $1.name }
    }

    private func add(name: String, value: String, scope: SecretScope, synced: Bool, note: String?) {
        do {
            try SecretsStore.upsert(name: name, value: value, scope: scope, synced: synced, note: note)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func edit(original: SecretMetadata, name: String, value: String, scope: SecretScope, synced: Bool, note: String?) {
        do {
            _ = try SecretsStore.update(
                original: original,
                name: name,
                value: value.isEmpty ? nil : value,
                scope: scope,
                synced: synced,
                note: note
            )
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ meta: SecretMetadata) {
        do { try SecretsStore.delete(meta); reload() }
        catch { errorMessage = error.localizedDescription }
    }

    private func purge(_ projectId: String) {
        do { try SecretsStore.purgeProject(projectId); reload() }
        catch { errorMessage = error.localizedDescription }
    }
}

private struct AddSecretSheet: View {
    enum ScopeChoice: String, CaseIterable, Identifiable {
        case permanent, project
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var scopeChoice: ScopeChoice = .permanent
    @State private var projectId = ""
    @State private var syncAcrossMacs = true
    @State private var note = ""

    let onSave: (String, String, SecretScope, Bool, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Secret").font(.title3.bold())
            Form {
                TextField("Name (e.g. github_token)", text: $name)
                SecureField("Value (paste token)", text: $value)
                Picker("Scope", selection: $scopeChoice) {
                    Text("Permanent (all projects)").tag(ScopeChoice.permanent)
                    Text("This project only").tag(ScopeChoice.project)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: scopeChoice) { _, newValue in
                    syncAcrossMacs = (newValue == .permanent)
                }
                if scopeChoice == .project {
                    TextField("Project name", text: $projectId)
                }
                Toggle("Sync across my Macs (iCloud Keychain)", isOn: $syncAcrossMacs)
                TextField("Note (optional)", text: $note)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let scope: SecretScope = scopeChoice == .project
                        ? .project(projectId.trimmingCharacters(in: .whitespaces))
                        : .global
                    onSave(name, value, scope, syncAcrossMacs, note.isEmpty ? nil : note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.isEmpty
            && (scopeChoice == .permanent || !projectId.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

private struct EditSecretSheet: View {
    enum ScopeChoice: String, CaseIterable, Identifiable {
        case permanent, project
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    let meta: SecretMetadata
    let onSave: (String, String, SecretScope, Bool, String?) -> Void

    @State private var name: String
    @State private var value: String
    @State private var scopeChoice: ScopeChoice
    @State private var projectId: String
    @State private var syncAcrossMacs: Bool
    @State private var note: String

    init(meta: SecretMetadata, onSave: @escaping (String, String, SecretScope, Bool, String?) -> Void) {
        self.meta = meta
        self.onSave = onSave
        _name = State(initialValue: meta.name)
        _value = State(initialValue: "")
        switch meta.scope {
        case .global:
            _scopeChoice = State(initialValue: .permanent)
            _projectId = State(initialValue: "")
        case .project(let id):
            _scopeChoice = State(initialValue: .project)
            _projectId = State(initialValue: id)
        }
        _syncAcrossMacs = State(initialValue: meta.synced)
        _note = State(initialValue: meta.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Secret").font(.title3.bold())
            Form {
                TextField("Name", text: $name)
                SecureField("Value (leave empty to keep current)", text: $value)
                Picker("Scope", selection: $scopeChoice) {
                    Text("Permanent (all projects)").tag(ScopeChoice.permanent)
                    Text("This project only").tag(ScopeChoice.project)
                }
                .pickerStyle(.radioGroup)
                if scopeChoice == .project {
                    TextField("Project name", text: $projectId)
                }
                Toggle("Sync across my Macs (iCloud Keychain)", isOn: $syncAcrossMacs)
                TextField("Note (optional)", text: $note)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let scope: SecretScope = scopeChoice == .project
                        ? .project(projectId.trimmingCharacters(in: .whitespaces))
                        : .global
                    onSave(name, value, scope, syncAcrossMacs, note.isEmpty ? nil : note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 460)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (scopeChoice == .permanent || !projectId.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

struct ModelsSettingsTab: View {
    @Environment(ModelCatalog.self) private var catalog
    @Environment(MLXInferenceEngine.self) private var engine
    @AppStorage("models.localRoot") private var modelsRoot: String = ""
    /// Download gating: hide models whose estimated memory need (weights +
    /// 25% runtime headroom) exceeds this Mac's residency budget. Remote and
    /// already-downloaded models always show. ON by default so a low-memory
    /// Mac never offers a download that would only swap-crash.
    @AppStorage("models.onlyShowFitting") private var onlyShowFitting = true
    @State private var hubModelID: String = ""
    @State private var loadingModelID: String? = nil
    @State private var showingAddProvider = false
    @State private var providerStore = RemoteProviderStore.shared
    private let sampler = ModelActivitySampler.shared

    /// "Can this Mac ever hold this model" test: weights + ~25% runtime
    /// headroom (KV cache, activations, Metal buffers) against the residency
    /// budget — the same numbers the engine's load guard enforces.
    private func fitInfo(_ model: MaestroModel) -> (fits: Bool, requiredGB: Int, budgetGB: Int) {
        let requiredGB = model.estimatedMemoryGB + model.estimatedMemoryGB / 4
        let budgetGB = engine.residentBudgetBytes / 1_073_741_824
        return (requiredGB <= budgetGB, requiredGB, budgetGB)
    }

    /// The visible catalog: remote models and on-disk models always show;
    /// undownloaded local models hide when they can't fit (unless the user
    /// turns the filter off to see everything).
    private var visibleModels: [MaestroModel] {
        catalog.models.filter { model in
            if model.isRemote || model.localPath != nil { return true }
            return !onlyShowFitting || fitInfo(model).fits
        }
    }

    /// True when this Mac is small enough that local models mostly don't fit —
    /// used to surface the remote-provider hint banner.
    private var isLowMemoryMac: Bool {
        ProcessInfo.processInfo.physicalMemory < 36_700_000_000  // < ~34 GiB
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Inference") {
                    Text("All generation runs fully on-device via Apple MLX (mlx-swift-lm). No server, no external runtime.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                GroupBox("System Memory (live)") {
                    SettingsMemoryBar(
                        residentModelBytes: engine.residentUsedBytes,
                        residentBudgetBytes: engine.residentBudgetBytes
                    )
                    .padding(8)
                }
                GroupBox("Resident Models (loaded in memory)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("~\(engine.residentUsedBytes / 1_073_741_824) GB of ~\(engine.residentBudgetBytes / 1_073_741_824) GB budget used (reserves 20% of system RAM for the OS). Models stay loaded for instant switching; the least-recently-used is evicted only when a new model won't fit. A model whose memory need exceeds the live system-wide free memory is refused with a clear error instead of stalling the Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        let list = engine.residentModelsReadout
                        if list.isEmpty {
                            Text("No models loaded yet.").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ForEach(list) { item in
                                HStack {
                                    Text(item.name).font(.caption)
                                    Spacer()
                                    Text("~\(item.gb) GB").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                GroupBox("Models folder") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Where MLX models are stored and downloaded. Defaults to this app's Application Support folder (portable to any Mac). Set a custom path to use an existing collection. Relaunch to apply.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField(ModelCatalog.modelsRoot, text: $modelsRoot)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(8)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("MLX Models (download from Hugging Face on first use)")
                                .font(.headline)
                            Spacer()
                            Toggle("Only models that fit this Mac", isOn: $onlyShowFitting)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                                .help("Hide downloads whose estimated memory need exceeds this Mac's residency budget (~\(engine.residentBudgetBytes / 1_073_741_824) GB). Downloaded and remote models always show.")
                            Button {
                                catalog.refreshLocalPaths()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Refresh local model paths")
                        }
                        if onlyShowFitting,
                           catalog.models.count > visibleModels.count {
                            let hidden = catalog.models.count - visibleModels.count
                            Text("\(hidden) model\(hidden == 1 ? "" : "s") hidden — too large for this Mac's memory.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if isLowMemoryMac {
                            Label(
                                "This Mac has \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB unified memory — most local models won't fit. Add a remote provider below (LM Studio or Ollama on another machine, or an online API like Kimi or Qwen) and chat with full-size models anyway.",
                                systemImage: "cloud"
                            )
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
                        }
                        ForEach(visibleModels) { model in
                            HStack(alignment: .top, spacing: 8) {
                                // Provenance dot: local MLX (green) vs remote
                                // provider (blue/purple/orange), matching the
                                // model pickers.
                                Image(nsImage: ChatView.badgeDotImage(model.providerBadge.colorName, size: 12))
                                    .padding(.top, 3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName).font(.body.bold())
                                    if let localPath = model.localPath {
                                        Text(localPath.replacingOccurrences(
                                            of: ModelCatalog.modelsRoot,
                                            with: ""))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    } else {
                                        Text(model.huggingFaceID)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                modelStatus(model: model)
                                if model.isRemote {
                                    Text("Remote").font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "cloud").foregroundStyle(.blue)
                                        .help("Runs on a remote OpenAI-compatible endpoint — uses no local memory")
                                } else {
                                    Text("~\(model.estimatedMemoryGB)GB").font(.caption).foregroundStyle(.secondary)
                                }
                                if model.isVision {
                                    Image(systemName: "eye").foregroundStyle(.blue)
                                }
                            }
                            .padding(.vertical, 2)
                            Divider()
                        }
                        HStack {
                            TextField("Hub ID (e.g. mlx-community/Qwen3-8B-4bit)", text: $hubModelID)
                                .textFieldStyle(.roundedBorder)
                            Button("Add") {
                                guard !hubModelID.isEmpty else { return }
                                let name = hubModelID.components(separatedBy: "/").last ?? hubModelID
                                catalog.addHubModel(name: name, huggingFaceID: hubModelID, isVision: false, memoryGB: 4)
                                hubModelID = ""
                            }
                            .disabled(hubModelID.isEmpty)
                        }
                    }
                    .padding(8)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Remote Providers")
                                .font(.headline)
                            Spacer()
                            Button {
                                showingAddProvider = true
                            } label: {
                                Label("Add Provider", systemImage: "plus")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                        Text("Run models without loading them locally — LM Studio or Ollama on this Mac or another machine on your network, or an online API (Kimi, Qwen, OpenRouter…). Uses no local memory, so any size model works on any Mac. API keys are stored in the Keychain via the Secrets tab, never in settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if providerStore.providers.isEmpty {
                            Text("No remote providers configured.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(providerStore.providers) { provider in
                                RemoteProviderRow(provider: provider)
                                Divider()
                            }
                        }
                    }
                    .padding(8)
                }
                Spacer()
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingAddProvider) {
            AddRemoteProviderSheet()
        }
        .onAppear {
            // Rescan the model root so models that live under the
            // swiftmaestro-models/ layout are recognized without requiring a
            // manual download attempt.
            catalog.refreshLocalPaths()
        }
    }

    /// Live status for a model row: downloading, explicit loading,
    /// loaded with unload, ready with load, or missing/repairable.
    @ViewBuilder
    private func modelStatus(model: MaestroModel) -> some View {
        let isResident = engine.residentModelsReadout.contains { $0.id == model.id }

        if engine.modelDownloadProgress[model.id] != nil {
            let progress = engine.modelDownloadProgress[model.id]
            HStack(spacing: 6) {
                if let progress {
                    ProgressView(value: progress)
                        .frame(width: 60)
                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                } else {
                    ProgressView()
                        .frame(width: 16)
                    Text("Queued…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if loadingModelID == model.id {
            HStack(spacing: 6) {
                ProgressView()
                    .frame(width: 16)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if isResident, let activity = sampler.models[model.id] {
            HStack(spacing: 6) {
                Circle()
                    .fill(activityStateColor(activity.state))
                    .frame(width: 6, height: 6)
                Text(activityStateText(activity.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if activity.state == .generating {
                    Text(String(format: "%.1f tok/s", activity.currentTokensPerSecond))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    engine.unloadModel(model.id)
                    sampler.remove(id: model.id)
                } label: {
                    Image(systemName: "eject")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Unload \(model.displayName) from memory")
            }
        } else if model.hasLocalWeights, !model.hasCompleteLocalWeights {
            // Weights are present but at least one shard from
            // model.safetensors.index.json is missing — an interrupted or
            // partial download. Distinct from "missing metadata": this needs
            // a real re-download of weight bytes, not just a small config
            // file repair, and loading it as-is would crash the app.
            let missingCount = ModelFileHealthService.missingWeightShards(for: model).count
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Incomplete download (\(missingCount) shard\(missingCount == 1 ? "" : "s") missing)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task {
                        try? await engine.downloadModel(model, repair: true)
                        catalog.refreshLocalPaths()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Re-download \(model.displayName) — existing files are kept and resumed; only missing bytes are fetched")
            }
            .help("Some weight files are missing on disk; this model cannot be loaded until re-downloaded")
        } else if model.hasLocalWeights {
            let metadataComplete = ModelFileHealthService.isMetadataComplete(for: model)
            HStack(spacing: 4) {
                if metadataComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        loadingModelID = model.id
                        Task {
                            _ = try? await engine.loadModel(model)
                            loadingModelID = nil
                        }
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .help("Load \(model.displayName) into memory")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Missing metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            try? await engine.downloadModel(model, repair: false)
                            catalog.refreshLocalPaths()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .help("Repair missing metadata files for \(model.displayName)")
                }
            }
            .help(metadataComplete ? "Downloaded locally" : "Weights present but metadata files are missing")
        } else if model.isRemote {
            // Remote models run elsewhere — nothing to download or load here.
            // A quick reachability probe doubles as the row's status.
            HStack(spacing: 4) {
                Image(systemName: "network").foregroundStyle(.secondary)
                Text("Endpoint").font(.caption).foregroundStyle(.secondary)
            }
            .help(model.remoteBaseURL ?? "Remote endpoint")
        } else if !fitInfo(model).fits {
            // Download gating: never offer a download that this Mac could only
            // ever load into swap-death. (The engine's load guard would refuse
            // it anyway — this just says so before a multi-GB download.)
            let info = fitInfo(model)
            Text("Won't fit — needs ~\(info.requiredGB) GB, budget ~\(info.budgetGB) GB")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("This model's estimated memory need (weights + runtime headroom) exceeds this Mac's model budget. Load it via a remote provider instead — LM Studio/Ollama on a bigger Mac, or an online API.")
        } else {
            let isRepair = model.localPath != nil
            Button {
                Task {
                    try? await engine.downloadModel(model, repair: isRepair)
                    catalog.refreshLocalPaths()
                }
            } label: {
                Label {
                    Text(isRepair ? "Repair" : "Download \(model.estimatedMemoryGB)GB")
                        .font(.caption.weight(.semibold))
                } icon: {
                    Image(systemName: isRepair
                          ? "arrow.clockwise.circle.fill"
                          : "arrow.down.circle.fill")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRepair ? Color.orange.opacity(0.15) : Color.blue.opacity(0.15))
                )
                .foregroundStyle(isRepair ? .orange : .blue)
            }
            .buttonStyle(.plain)
            .help(isRepair
                  ? "Repair incomplete download"
                  : "Download ~\(model.estimatedMemoryGB)GB from Hugging Face")
        }
    }

    private func activityStateColor(_ state: ModelActivityState) -> Color {
        switch state {
        case .loading: return .orange
        case .generating: return .blue
        case .idle: return .green
        }
    }

    private func activityStateText(_ state: ModelActivityState) -> String {
        switch state {
        case .loading: return "Loading"
        case .generating: return "Generating"
        case .idle: return "Ready"
        }
    }
}

// MARK: - Remote Providers UI

/// One configured remote provider in Settings → Models, with reachability
/// probe and edit/delete actions.
private struct RemoteProviderRow: View {
    let provider: RemoteProvider
    @State private var providerStore = RemoteProviderStore.shared
    @State private var probing = false
    @State private var probeResult: RemoteProviderStore.ProbeResult?
    @State private var showingEdit = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "cloud.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.body.bold())
                Text("\(provider.kind.rawValue) · \(provider.baseURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(provider.modelIDs.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if probing {
                ProgressView().frame(width: 14)
            } else if let probeResult {
                switch probeResult {
                case .ok(let count):
                    Text("\(count) model\(count == 1 ? "" : "s") reachable")
                        .font(.caption).foregroundStyle(.green)
                case .reachableNeedsAuth:
                    Text("Reachable — needs API key")
                        .font(.caption).foregroundStyle(.orange)
                case .reachableUnexpected(let status):
                    Text("Answered (HTTP \(status))")
                        .font(.caption).foregroundStyle(.orange)
                case .failed:
                    Text("Unreachable").font(.caption).foregroundStyle(.red)
                }
            }
            Button {
                probing = true
                probeResult = nil
                Task {
                    let (result, _) = await RemoteProviderStore.probe(provider)
                    probeResult = result
                    probing = false
                }
            } label: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Test connection to \(provider.baseURL)")
            Button {
                showingEdit = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Edit provider")
            Button {
                providerStore.remove(id: provider.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.8))
            .help("Remove provider (its models leave the picker immediately)")
        }
        .sheet(isPresented: $showingEdit) {
            AddRemoteProviderSheet(existing: provider)
        }
    }
}

/// Add/edit sheet for a remote provider. API keys are written to the Keychain
/// via SecretsStore and stored on the provider only as a `secret://` reference.
private struct AddRemoteProviderSheet: View {
    /// When set, the sheet edits this provider instead of creating one.
    let existing: RemoteProvider?

    @Environment(\.dismiss) private var dismiss
    @State private var providerStore = RemoteProviderStore.shared

    @State private var kind: RemoteProviderKind
    @State private var presetID: String = ""
    @State private var name: String
    @State private var baseURL: String
    @State private var modelIDsText: String
    @State private var apiKey: String = ""
    @State private var fetchingModels = false
    @State private var statusLine: String?

    init(existing: RemoteProvider? = nil) {
        self.existing = existing
        _kind = State(initialValue: existing?.kind ?? .lmStudio)
        _name = State(initialValue: existing?.name ?? "")
        _baseURL = State(initialValue: existing?.baseURL ?? RemoteProviderKind.lmStudio.defaultBaseURL)
        _modelIDsText = State(initialValue: existing?.modelIDs.joined(separator: ", ") ?? "")
    }

    private var parsedModelIDs: [String] {
        modelIDsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !parsedModelIDs.isEmpty
            && (kind != .online || !apiKey.isEmpty || existing?.apiKeyRef != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add Remote Provider" : "Edit Remote Provider")
                .font(.title2.bold())

            Picker("Type", selection: $kind) {
                ForEach(RemoteProviderKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, newKind in
                if baseURL.isEmpty || baseURL == kind.defaultBaseURL || RemoteProviderKind.allCases.map(\.defaultBaseURL).contains(baseURL) {
                    baseURL = newKind.defaultBaseURL
                }
                if name.isEmpty { name = newKind.rawValue }
            }

            if kind == .online {
                Picker("Preset", selection: $presetID) {
                    Text("Custom").tag("")
                    ForEach(RemoteProviderPreset.presets) { Text($0.name).tag($0.id) }
                }
                .onChange(of: presetID) { _, newID in
                    guard let preset = RemoteProviderPreset.presets.first(where: { $0.id == newID }) else { return }
                    name = preset.name
                    baseURL = preset.baseURL
                    if modelIDsText.isEmpty { modelIDsText = preset.suggestedModels.joined(separator: ", ") }
                }
                if let preset = RemoteProviderPreset.presets.first(where: { $0.id == presetID }) {
                    Text(preset.keyHelp).font(.caption).foregroundStyle(.secondary)
                }
            }

            TextField("Name (e.g. LM Studio on Studio Mac)", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Base URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Model IDs, comma-separated (e.g. kimi-k3, qwen3:8b)", text: $modelIDsText)
                    .textFieldStyle(.roundedBorder)
                Button("Fetch") {
                    fetchingModels = true
                    statusLine = nil
                    let probeProvider = RemoteProvider(
                        id: existing?.id ?? UUID(),
                        name: name, kind: kind, baseURL: baseURL,
                        modelIDs: [], apiKeyRef: existing?.apiKeyRef)
                    Task {
                        let (result, ids) = await RemoteProviderStore.probe(probeProvider)
                        fetchingModels = false
                        switch result {
                        case .ok(let count):
                            if !ids.isEmpty { modelIDsText = ids.joined(separator: ", ") }
                            statusLine = "Connected — \(count) model(s) reported."
                        case .reachableNeedsAuth:
                            statusLine = "Server reachable — it wants the API key first. Paste it above and Save; the key is verified on first chat."
                        case .reachableUnexpected(let status):
                            statusLine = "Server answered (HTTP \(status)) but didn't return a model list — check the base URL."
                        case .failed(let message):
                            statusLine = message
                        }
                    }
                }
                .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty || fetchingModels)
            }

            if kind == .online {
                SecureField(
                    existing?.apiKeyRef != nil
                        ? "API key (leave blank to keep the existing one)"
                        : "API key",
                    text: $apiKey
                )
                .textFieldStyle(.roundedBorder)
            }

            if let statusLine {
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(existing == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // API key → Keychain via SecretsStore; the provider keeps only the
        // `secret://` reference. Blank in edit mode keeps the existing key.
        var keyRef = existing?.apiKeyRef
        if kind == .online, !apiKey.isEmpty {
            let secretName = "remote-\(trimmedName.lowercased().replacingOccurrences(of: " ", with: "-"))-api-key"
            do {
                _ = try SecretsStore.upsert(
                    name: secretName,
                    value: apiKey,
                    scope: .global,
                    synced: true,
                    note: "API key for remote provider \(trimmedName)")
                keyRef = "secret://\(secretName)"
            } catch {
                statusLine = "Couldn't store the API key in the Keychain: \(error.localizedDescription)"
                return
            }
        }
        if kind != .online { keyRef = nil }

        let provider = RemoteProvider(
            id: existing?.id ?? UUID(),
            name: trimmedName,
            kind: kind,
            baseURL: trimmedURL,
            modelIDs: parsedModelIDs,
            apiKeyRef: keyRef,
            requestTimeout: existing?.requestTimeout ?? (kind == .online ? 300 : 180))
        if existing == nil {
            providerStore.add(provider)
        } else {
            providerStore.update(provider)
        }
        dismiss()
    }
}

/// Per-model sampling. A model picker scopes every slider to one model, so it's
/// always clear WHICH model is being tuned. Values default to that model's
/// recommended sampling and are saved per `model.id`; "Reset to recommended"
/// clears the override. The generation path reads the same values via
/// `MaestroModel.tuned*`, so chat honours exactly what's shown here.
struct TuningSettingsTab: View {
    @Environment(ModelCatalog.self) private var catalog

    @State private var selectedModelID: String = ModelCatalog.defaultModelID
    @State private var temperature: Double = 1.0
    @State private var topP: Double = 0.95
    @State private var repetitionPenalty: Double = 1.05
    @State private var maxTokens: Double = 32768
    @State private var thinkingEnabled: Bool = false

    private var model: MaestroModel? {
        catalog.models.first { $0.id == selectedModelID } ?? catalog.selectedModel
    }
    private var recTemp: Double { model?.recTemperature ?? 1.0 }
    private var recTopP: Double { model?.recTopP ?? 0.95 }
    private var recRepPen: Double { model?.recRepetitionPenalty ?? 1.05 }
    private var recMaxTok: Int { model?.recMaxTokens ?? 32768 }
    private var hasOverride: Bool {
        isCustom(temperature, recTemp) || isCustom(topP, recTopP)
            || isCustom(repetitionPenalty, recRepPen)
            || Int(maxTokens) != recMaxTok
            || thinkingEnabled
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Model") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Tuning for", selection: $selectedModelID) {
                            ForEach(catalog.models) { m in Text(m.displayName).tag(m.id) }
                        }
                        Text("Sampling below is saved for this model and applies wherever it runs — for every agent that uses it. Each model keeps its own values.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                GroupBox("Sampling — \(model?.displayName ?? "model")") {
                    VStack(spacing: 14) {
                        sliderRow("Temperature", $temperature, range: 0...2, step: 0.05,
                                  recommended: recTemp, param: "temperature",
                                  description: "Controls randomness. Lower (0.2–0.6) = focused, predictable. Higher (0.8–1.2) = creative, varied. Too high causes hallucination.")
                        sliderRow("Top-P", $topP, range: 0...1, step: 0.05,
                                  recommended: recTopP, param: "topP",
                                  description: "Nucleus sampling. Limits token choices to the top P% probability mass. Lower = safer, more repetitive. Higher = more diverse.")
                        sliderRow("Repetition Penalty", $repetitionPenalty, range: 1...1.5, step: 0.01,
                                  recommended: recRepPen, param: "repetitionPenalty",
                                  description: "Penalises tokens already used. 1.0 = no penalty. 1.1–1.2 = mild reduction. 1.2+ = strong reduction. Too high can make output sound unnatural.")
                        // Max output tokens — integer slider with K-suffix display
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Max Output Tokens").frame(width: 150, alignment: .leading)
                                Slider(value: $maxTokens, in: 512...262144, step: 512, onEditingChanged: { editing in
                                    if !editing {
                                        UserDefaults.standard.set(
                                            Int(maxTokens),
                                            forKey: MaestroModel.tuningKey(selectedModelID, "maxTokens"))
                                    }
                                })
                                Text(formatTokens(Int(maxTokens)))
                                    .monospacedDigit().frame(width: 56)
                            }
                            Text("Maximum tokens the model can generate per response. Higher = longer answers but slower. 32K is a good default; 64K+ for long-form writing.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Int(maxTokens) != recMaxTok
                                 ? "Custom · recommended \(formatTokens(recMaxTok)) for this model"
                                 : "Using model recommended (\(formatTokens(recMaxTok)))")
                                .font(.caption2).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Toggle("Enable thinking / reasoning", isOn: $thinkingEnabled)
                        Text("Lets models that support it reason step-by-step before answering. Per-model setting.")
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Reset to recommended") { resetToRecommended() }
                                .disabled(!hasOverride)
                        }
                    }
                    .padding(8)
                }
                Spacer()
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            if selectedModelID.isEmpty {
                selectedModelID = catalog.selectedModel?.id ?? catalog.models.first?.id ?? ""
            }
            loadValues()
        }
        .onChange(of: selectedModelID) { _, _ in loadValues() }
        .onChange(of: thinkingEnabled) { _, _ in
            UserDefaults.standard.set(thinkingEnabled, forKey: MaestroModel.tuningKey(selectedModelID, "thinking"))
        }
    }

    @ViewBuilder
    private func sliderRow(
        _ label: String, _ value: Binding<Double>,
        range: ClosedRange<Double>, step: Double, recommended: Double, param: String,
        description: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).frame(width: 150, alignment: .leading)
                Slider(value: value, in: range, step: step, onEditingChanged: { editing in
                    if !editing {
                        UserDefaults.standard.set(
                            value.wrappedValue,
                            forKey: MaestroModel.tuningKey(selectedModelID, param))
                    }
                })
                Text(fmt(value.wrappedValue)).monospacedDigit().frame(width: 46)
            }
            if !description.isEmpty {
                Text(description)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(isCustom(value.wrappedValue, recommended)
                 ? "Custom · recommended \(fmt(recommended)) for this model"
                 : "Using model recommended (\(fmt(recommended)))")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadValues() {
        guard let model else { return }
        let d = UserDefaults.standard
        temperature = (d.object(forKey: MaestroModel.tuningKey(model.id, "temperature")) as? Double)
            ?? (model.recTemperature ?? 1.0)
        topP = (d.object(forKey: MaestroModel.tuningKey(model.id, "topP")) as? Double)
            ?? (model.recTopP ?? 0.95)
        repetitionPenalty = (d.object(forKey: MaestroModel.tuningKey(model.id, "repetitionPenalty")) as? Double)
            ?? (model.recRepetitionPenalty ?? 1.05)
        maxTokens = Double((d.object(forKey: MaestroModel.tuningKey(model.id, "maxTokens")) as? Int)
            ?? (model.recMaxTokens ?? 32768))
        thinkingEnabled = (d.object(forKey: MaestroModel.tuningKey(model.id, "thinking")) as? Bool)
            ?? false
    }

    private func resetToRecommended() {
        let d = UserDefaults.standard
        for p in ["temperature", "topP", "repetitionPenalty", "maxTokens", "thinking"] {
            d.removeObject(forKey: MaestroModel.tuningKey(selectedModelID, p))
        }
        loadValues()
    }

    private func isCustom(_ value: Double, _ recommended: Double) -> Bool {
        abs(value - recommended) > 0.0001
    }
    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
    /// Format token counts with K suffix for readability (e.g. 32768 → "32K")
    private func formatTokens(_ n: Int) -> String {
        if n >= 1024 && n % 1024 == 0 { return "\(n / 1024)K" }
        return "\(n)"
    }
}

struct RulesSettingsTab: View {
    @State private var rules: [AgentRule] = []
    @State private var selectedScope: String = "All"
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Agent Rules") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Scope")
                            Picker("", selection: $selectedScope) {
                                Text("All Agents").tag("All")
                                ForEach(Agent.defaultAgentNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .frame(width: 200)
                        }
                        Text(selectedScope == "All"
                             ? "Rules applied to every agent."
                             : "Rules applied to \(selectedScope), in addition to All Agents rules.")
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        if !rules.contains(where: { $0.scope == selectedScope }) {
                            Text("No rules yet. Add a rule below; enabled rules are injected as a system instruction at the start of each conversation.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach($rules) { $rule in
                            if rule.scope == selectedScope {
                                HStack(alignment: .top) {
                                    Toggle("", isOn: $rule.enabled).labelsHidden()
                                    TextField("Rule text", text: $rule.text, axis: .vertical)
                                        .textFieldStyle(.roundedBorder)
                                        .lineLimit(1...6)
                                    Button { rules.removeAll { $0.id == rule.id } } label: {
                                        Image(systemName: "trash").foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Button {
                            rules.append(AgentRule(text: "", enabled: true, scope: selectedScope))
                        } label: {
                            Label("Add Rule", systemImage: "plus")
                        }
                    }
                    .padding(8)
                }
                Spacer()
                HStack {
                    if let saveMessage {
                        Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Settings") {
                        let cleaned = rules.filter {
                            !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
                        }
                        SwiftMaestroSettingsStore.saveRules(cleaned)
                        rules = cleaned
                        saveMessage = "Saved"
                    }
                }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            rules = SwiftMaestroSettingsStore.loadRules()
        }
    }
}

struct ContextSettingsTab: View {
    @State private var selectedAgent: String = "All"
    @State private var authorizedFolders: [AuthorizedFolder] = []
    @State private var newFolderPath: String = ""
    @State private var importScope: String = "Maestro (parent)"
    @State private var importFolderPath: String = ""
    @State private var importStatus: String = ""
    @State private var filesInMemory: Int = 0
    @State private var lastImportDate: String = ""
    @State private var collapseCompactionSummaries: Bool = false
    @State private var fullDiskAccess: Bool = false
    /// The real macOS TCC Full Disk Access grant (kTCCServiceSystemPolicyAllFiles)
    /// — probed live from the system, completely separate from the in-app
    /// toggle above it (which only bypasses the Authorized Folders list).
    @State private var macOSFullDiskAccess: Bool = false
    @State private var saveMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Full Disk Access") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Unrestricted agent file access (bypasses Authorized Folders)",
                            isOn: $fullDiskAccess)
                        Text("When enabled, agents can read and write files anywhere on the system, just like a terminal with Full Disk Access. This bypasses the Authorized Folders restrictions below.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if fullDiskAccess {
                            Label("Unrestricted access is ON — agents have unrestricted file system access", systemImage: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        Divider()

                        // The REAL macOS grant (TCC). Only the user can grant
                        // it in System Settings — the app can only detect it
                        // and deep-link to the pane. Applies at process launch.
                        HStack {
                            Label(
                                macOSFullDiskAccess
                                    ? "macOS Full Disk Access: granted"
                                    : "macOS Full Disk Access: not granted",
                                systemImage: macOSFullDiskAccess
                                    ? "checkmark.shield.fill"
                                    : "exclamationmark.shield.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(macOSFullDiskAccess ? .green : .orange)
                            Spacer()
                            Button("Recheck") {
                                macOSFullDiskAccess = FullDiskAccessService.isGranted()
                            }
                            .controlSize(.small)
                            Button("Open Settings…") {
                                FullDiskAccessService.openSystemSettings()
                            }
                            .controlSize(.small)
                        }
                        if !macOSFullDiskAccess {
                            Text("Required for Mail, Messages, Safari and other macOS-protected data. Turn SwiftMaestro ON in System Settings → Privacy & Security → Full Disk Access, then relaunch the app — macOS applies the grant at launch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                }
                GroupBox("Authorized Folders") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Agent")
                            Picker("", selection: $selectedAgent) {
                                Text("All Agents").tag("All")
                                ForEach(Agent.defaultAgentNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .frame(width: 150)
                        }
                        ForEach($authorizedFolders) { $folder in
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                                Text(folder.path).font(.caption).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Toggle("", isOn: $folder.enabled)
                                    .labelsHidden()
                                    .disabled(folder.path == SwiftMaestroPaths.appSupportDir.path)
                                Button { authorizedFolders.removeAll { $0.id == folder.id } } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .disabled(folder.path == SwiftMaestroPaths.appSupportDir.path)
                                .help(folder.path == SwiftMaestroPaths.appSupportDir.path
                                      ? "SwiftMaestro must access its own Application Support directory"
                                      : "Remove this folder")
                            }
                        }
                        HStack {
                            TextField("/absolute/path", text: $newFolderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Add Path") {
                                guard !newFolderPath.isEmpty else { return }
                                authorizedFolders.append(AuthorizedFolder(path: newFolderPath, enabled: true))
                                newFolderPath = ""
                            }
                        }
                        Text(importStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
                GroupBox("Import Folder Into Memory (v2)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Scope")
                            Picker("", selection: $importScope) {
                                Text("Maestro (parent)").tag("Maestro (parent)")
                                Text("Agent project (child)").tag("Agent project (child)")
                            }
                            .pickerStyle(.segmented)
                        }
                        HStack {
                            TextField("/absolute/path", text: $importFolderPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Import Folder") {
                                importStatus = "Importing..."
                            }
                        }
                        if filesInMemory > 0 {
                            Text("\(filesInMemory) file(s) in memory — \(lastImportDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                GroupBox("Chat Compaction") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(
                            "Collapse compaction summaries by default",
                            isOn: $collapseCompactionSummaries)
                        Text("When on, the \"Context compacted\" summary is collapsed until you expand it, with Show/Hide buttons at the top and bottom.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }
                Spacer()
                HStack {
                    if let saveMessage {
                        Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Settings") {
                        SwiftMaestroSettingsStore.saveAuthorizedFolders(authorizedFolders)
                        SwiftMaestroSettingsStore.saveFilesInMemory(filesInMemory)
                        SwiftMaestroSettingsStore.saveLastImportDate(lastImportDate)
                        SwiftMaestroSettingsStore.saveCollapseCompactionSummaries(collapseCompactionSummaries)
                        SwiftMaestroSettingsStore.saveFullDiskAccess(fullDiskAccess)
                        saveMessage = "Saved"
                    }
                }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            authorizedFolders = SwiftMaestroSettingsStore.loadAuthorizedFolders()
            filesInMemory = SwiftMaestroSettingsStore.loadFilesInMemory()
            lastImportDate = SwiftMaestroSettingsStore.loadLastImportDate()
            fullDiskAccess = SwiftMaestroSettingsStore.loadFullDiskAccess()
            macOSFullDiskAccess = FullDiskAccessService.isGranted()
            SwiftMaestroSettingsStore.saveCollapseCompactionSummaries(collapseCompactionSummaries)
        }
    }
}

struct MCPSettingsTab: View {
    @State private var servers: [MCPServerEntry] = []
    @State private var saveMessage: String?
    @State private var presetAlert: PresetAlert?

    private enum PresetAlert: Identifiable {
        case overwriteCustom, overwriteBundled, noCustomPreset

        var id: String {
            switch self {
            case .overwriteCustom: return "overwriteCustom"
            case .overwriteBundled: return "overwriteBundled"
            case .noCustomPreset: return "noCustomPreset"
            }
        }

        var title: String {
            switch self {
            case .overwriteCustom:
                return "Save Custom Preset"
            case .overwriteBundled:
                return "Switch to Bundled Preset"
            case .noCustomPreset:
                return "No Custom Preset"
            }
        }

        var message: String {
            switch self {
            case .overwriteCustom:
                return "This will overwrite your saved custom preset with the current server list."
            case .overwriteBundled:
                return "This will replace your current server list with the self-contained bundled servers. Switch back anytime using your saved custom preset."
            case .noCustomPreset:
                return "No custom preset has been saved yet. Save the current list as a custom preset first."
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                presetBar

                ForEach($servers) { $server in
                    MCPServerRow(server: $server, onDelete: {
                        servers.removeAll { $0.id == server.id }
                    })
                }
                Button {
                    servers.append(MCPServerEntry(name: "new-server", command: MCPServerEntry.bundledNode, scriptPath: "", env: "", workingDir: "", timeout: 8, enabled: false))
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                Spacer()
                HStack {
                    if let saveMessage {
                        Text(saveMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Settings") {
                        SwiftMaestroSettingsStore.saveMCPServers(servers)
                        saveMessage = "Saved"
                    }
                }
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            servers = SwiftMaestroSettingsStore.loadMCPServers()
        }
        .alert(item: $presetAlert) { alert in
            switch alert {
            case .overwriteCustom:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Save")) {
                        SwiftMaestroSettingsStore.saveCustomMCPPreset(servers)
                        saveMessage = "Custom preset saved"
                    },
                    secondaryButton: .cancel()
                )
            case .overwriteBundled:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Switch")) {
                        applyBundledPreset()
                    },
                    secondaryButton: .cancel()
                )
            case .noCustomPreset:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    @ViewBuilder
    private var presetBar: some View {
        GroupBox("MCP Presets") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Switch between your custom configuration and the self-contained bundled servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button {
                        presetAlert = .overwriteCustom
                    } label: {
                        Label("Save as Custom Preset", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        if let custom = SwiftMaestroSettingsStore.loadCustomMCPPreset() {
                            servers = custom
                            SwiftMaestroSettingsStore.saveMCPServers(custom)
                            saveMessage = "Switched to custom preset"
                        } else {
                            presetAlert = .noCustomPreset
                        }
                    } label: {
                        Label("Use Custom Preset", systemImage: "person")
                    }

                    Button {
                        presetAlert = .overwriteBundled
                    } label: {
                        Label("Use Bundled Preset", systemImage: "cube.box")
                    }

                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(8)
        }
    }

    private func applyBundledPreset() {
        let bundled = MCPServerBundleService.shared.bundledEntries()
        guard !bundled.isEmpty else {
            saveMessage = "No bundled servers found"
            return
        }
        servers = bundled
        SwiftMaestroSettingsStore.saveMCPServers(bundled)
        saveMessage = "Switched to bundled preset"
    }
}



/// `MCPClientService` is a plain `actor`, not `@Observable`, so it can't use
/// the newer `@Environment(Type.self)` sugar (that requires Observable
/// conformance). A classic `EnvironmentKey` works for any reference type.
private struct MCPClientServiceKey: EnvironmentKey {
    static let defaultValue: MCPClientService? = nil
}

extension EnvironmentValues {
    var mcpClientService: MCPClientService? {
        get { self[MCPClientServiceKey.self] }
        set { self[MCPClientServiceKey.self] = newValue }
    }
}

struct MCPServerRow: View {
    @Binding var server: MCPServerEntry
    var onDelete: () -> Void
    @Environment(\.mcpClientService) private var mcpService

    private enum ViewMode: String, CaseIterable { case summary = "Summary", fields = "Fields", snippet = "Snippet" }
    @State private var mode: ViewMode = .summary
    @State private var liveTools: [String] = []
    @State private var liveConnected = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(server.enabled ? .green : .gray).frame(width: 8, height: 8)
                    TextField("Server name", text: $server.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Spacer()
                    Toggle("", isOn: $server.enabled).labelsHidden()
                    Button { onDelete() } label: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 14) {
                    Text("Advertise tools to:")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Chat agents", isOn: Binding(
                        get: { server.advertisesToAgents },
                        set: { server.advertise = $0 }
                    ))
                    Toggle("Delegated sub-agents", isOn: Binding(
                        get: { server.advertisesToDelegates },
                        set: { server.advertiseToSubAgents = $0 }
                    ))
                    Spacer()
                }
                .font(.caption)
                .toggleStyle(.checkbox)
                .help("Untick to keep the server connected but leave its tools out of "
                    + "the prompt for that audience. Fewer advertised tools = smaller "
                    + "prompt = faster prefill. Applies from the next message.")
                HStack {
                    ForEach(ViewMode.allCases, id: \.self) { m in
                        Button(m.rawValue) { mode = m }
                            .buttonStyle(.bordered)
                            .tint(mode == m ? .blue : .gray)
                    }
                }
                switch mode {
                case .summary: summary
                case .fields: fields
                case .snippet: snippet
                }
            }
            .padding(6)
        }
        .task(id: server.name) {
            guard let mcpService else { return }
            liveConnected = await mcpService.isConnected(serverName: server.name)
            liveTools = await mcpService.toolNames(forServer: server.name)
        }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: liveConnected ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(liveConnected ? .green : .secondary)
                Text(liveConnected
                    ? "Connected — \(liveTools.count) tool\(liveTools.count == 1 ? "" : "s") discovered at last launch"
                    : (server.enabled
                        ? "Enabled, but not connected this launch (check the script path, or restart the app)"
                        : "Disabled"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !liveTools.isEmpty {
                Text(liveTools.joined(separator: ", "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("What does this server do?").font(.caption.weight(.semibold))
            TextField(
                "e.g. \"Web search + page scraping via Firecrawl\" — your own note, for your reference only",
                text: Binding(get: { server.notes ?? "" }, set: { server.notes = $0.isEmpty ? nil : $0 }),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
        }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Command", text: $server.command).textFieldStyle(.roundedBorder)
            TextField("Script path", text: $server.scriptPath).textFieldStyle(.roundedBorder)
            TextField("Arguments (one per line; overrides script path)", text: Binding(
                get: { (server.args ?? []).joined(separator: "\n") },
                set: { newValue in
                    let parts = newValue
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .map(String.init)
                    server.args = parts.isEmpty ? nil : parts
                }
            ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            TextField("Env", text: $server.env).textFieldStyle(.roundedBorder)
            TextField("Working directory", text: $server.workingDir).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Snippet

    /// Read-only, copyable rendering of this server's launch command — handy
    /// for comparing/copying definitions when reorganizing a large MCP
    /// server collection.
    private var snippet: some View {
        let argv = ([server.command] + (server.args ?? (server.scriptPath.isEmpty ? [] : [server.scriptPath])))
            .joined(separator: " ")
        let envLines = server.env
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var lines = [argv]
        lines += envLines
        if !server.workingDir.isEmpty { lines.append("cwd: \(server.workingDir)") }
        return Text(lines.joined(separator: "\n"))
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct AuthorizedFolder: Identifiable, Codable {
    var id: UUID = UUID()
    var path: String
    var enabled: Bool
}

/// A single behavioral rule for an agent. `scope` is either "All" (applies to
/// every agent) or a specific agent name.
struct AgentRule: Identifiable, Codable {
    var id: UUID = UUID()
    var text: String
    var enabled: Bool
    var scope: String

    /// Starter rules shown in the Rules tab and injected into the system prompt.
    /// These are user-editable; deleting or toggling them only affects the soft
    /// guidance layer — the hard anti-fabrication safety rules live in code and
    /// always apply. "All" rules apply to every agent; named scopes add on top.
    static let defaults: [AgentRule] = [
        AgentRule(text: "When a question can be answered with a tool you have, call "
            + "that tool instead of guessing or telling the user to do it themselves "
            + "(e.g. use execute_command for shell/system info, memory tools for "
            + "stored context, CrawlKit for web content).", enabled: true, scope: "All"),
        AgentRule(text: "Never claim you ran a command, created a file, or performed "
            + "any action unless a real tool result confirms it. If a tool returns "
            + "nothing, say exactly that — do not invent output.", enabled: true, scope: "All"),
        AgentRule(text: "After using a tool, report what it actually returned, then "
            + "answer the user's question based on that real result.", enabled: true, scope: "All"),
        AgentRule(text: "Be concise and direct. Skip filler, preamble, and repeated "
            + "disclaimers.", enabled: true, scope: "All"),
        AgentRule(text: "This is a self-hosted, offline-first macOS assistant. Prefer "
            + "the user's local models, files, and tools over external services.", enabled: true, scope: "All"),
        AgentRule(text: "If a request is ambiguous, ask one short clarifying question "
            + "instead of assuming.", enabled: true, scope: "All"),
        AgentRule(text: "Default to Swift for macOS/iOS work; do not assume Python or "
            + "any other language unless the user specifies it.", enabled: true, scope: "Coding"),
        AgentRule(text: "Provide complete, runnable code and explain only the "
            + "non-obvious parts.", enabled: true, scope: "Coding"),
    ]
}

struct MCPServerEntry: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var command: String
    var scriptPath: String
    var env: String
    var workingDir: String
    var timeout: Int
    var enabled: Bool
    /// Explicit argument vector passed to `command` verbatim. Needed for servers
    /// that take subcommands (e.g. `cli.js mcp`) or multiple args, which a single
    /// `scriptPath` can't express. When nil/empty the launcher falls back to
    /// `[scriptPath]`. Optional so older persisted configs still decode.
    var args: [String]? = nil
    /// Whether this server's tools are advertised to interactive chats (Maestro
    /// and project agents). Tool specs dominate the prompt — and on hybrid-cache
    /// models every fresh round re-prefills it all — so trimming exposure here
    /// directly cuts per-turn latency. Optional (nil = true) so older persisted
    /// configs still decode. The server stays connected either way; this only
    /// controls advertisement, so changes apply from the next message.
    var advertise: Bool? = nil
    /// Same as `advertise`, but for DELEGATED sub-agent runs (ask_project_agent/s).
    /// Sub-agents usually need memory/plan tools, not the full tool surface.
    var advertiseToSubAgents: Bool? = nil
    /// User-written free-text note on what this server actually does, shown in
    /// the Summary tab. Purely a label for the user's own reference — nothing
    /// else reads it. Optional (nil = not yet written) so older persisted
    /// configs still decode.
    var notes: String? = nil

    var advertisesToAgents: Bool { advertise ?? true }
    var advertisesToDelegates: Bool { advertiseToSubAgents ?? true }

    /// Pre-configured MCP servers that ship with SwiftMaestro. These appear in
    /// Node from the app-bundled MCP runtime — works without Homebrew. The
    /// bundled-manifest resolution replaces whole entries on fresh installs;
    /// this path keeps even unresolved defaults runnable on any machine.
    static let bundledNode = SwiftMaestroPaths.appSupportDir
        .appendingPathComponent("mcp-servers/.runtime/node/bin/node").path

    /// Settings → MCP on first launch. Enabled servers connect on launch;
    /// disabled ones are ready to toggle on when their backend is available.
    static let defaults: [MCPServerEntry] = [
        // ── Web search & scraping (pick one or more) ──
        MCPServerEntry(
            name: "webclaw",
            command: "/opt/homebrew/bin/webclaw-mcp",
            scriptPath: "",
            env: "",
            workingDir: "",
            timeout: 12,
            enabled: true ,
            notes: "Local-first web scraping (Rust binary, 12+ tools). Install: brew install webclaw"
        ),
        MCPServerEntry(
            name: "firecrawl",
            command: bundledNode,
            scriptPath: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/firecrawl-mcp-server/dist/index.js",
            env: "FIRECRAWL_API_URL=http://localhost:3002",
            workingDir: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/firecrawl-mcp-server",
            timeout: 15,
            enabled: true ,
            notes: "Deep web scrape/search/crawl. Requires Docker: cd ~/GitHub/AI-ML-Agents/firecrawl && docker-compose up -d"
        ),
        MCPServerEntry(
            name: "read-website-fast",
            command: bundledNode,
            scriptPath: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/mcp-read-website-fast/dist/serve-restart.js",
            env: "",
            workingDir: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/mcp-read-website-fast",
            timeout: 8,
            enabled: true,
            notes: "Fast single-page web extraction to clean markdown. No dependencies."
        ),
        // ── Infrastructure ──
        MCPServerEntry(
            name: "ai-context-bridge",
            command: bundledNode,
            scriptPath: "\(NSHomeDirectory())/.ai-context/mcp-server/server.js",
            env: "",
            workingDir: "\(NSHomeDirectory())/.ai-context/mcp-server",
            timeout: 10,
            enabled: true,
            notes: "Cross-project context, memory, knowledge, build tools (29 tools)."
        ),
        MCPServerEntry(
            name: "playwright",
            command: bundledNode,
            scriptPath: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/playwright-mcp/packages/playwright-mcp/cli.js",
            env: "HOME=\(NSHomeDirectory())",
            workingDir: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/playwright-mcp",
            timeout: 12,
            enabled: true,
            notes: "Browser automation, testing, vision, network, devtools."
        ),
        MCPServerEntry(
            name: "xcodebuildmcp",
            command: bundledNode,
            scriptPath: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/XcodeBuildMCP/build/cli.js",
            env: "HOME=\(NSHomeDirectory())\nXCODEBUILDMCP_ENABLED_WORKFLOWS=simulator,session-management,macos",
            workingDir: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/XcodeBuildMCP",
            timeout: 10,
            enabled: true,
            args: ["\(NSHomeDirectory())/GitHub/AI-ML-Agents/XcodeBuildMCP/build/cli.js", "mcp"],
            notes: "Xcode project management, simulator, macOS builds, app utilities."
        ),
        MCPServerEntry(
            name: "swift-terminals",
            command: bundledNode,
            scriptPath: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/Swift-terminals/dist/index.js",
            env: "",
            workingDir: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/Swift-terminals",
            timeout: 8,
            enabled: true,
            notes: "Persistent terminal sessions and shell execution."
        ),
        // ── Communication ──
        MCPServerEntry(
            name: "whatsapp",
            command: "/opt/homebrew/bin/uv",
            scriptPath: "",
            env: "",
            workingDir: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/whatsapp-mcp/whatsapp-mcp-server",
            timeout: 10,
            enabled: true,
            args: ["--directory", "\(NSHomeDirectory())/GitHub/AI-ML-Agents/whatsapp-mcp/whatsapp-mcp-server", "run", "main.py"],
            notes: "WhatsApp messaging. Requires bridge: cd ~/GitHub/AI-ML-Agents/whatsapp-mcp/whatsapp-bridge && go run main.go"
        ),
        // ── Web crawling (advanced, needs backend) ──
        MCPServerEntry(
            name: "crawlkit",
            command: bundledNode,
            scriptPath: "\(NSHomeDirectory())/.ai-context/mcp-crawlkit/server.js",
            env: "CRAWLKIT_BASE_URL=http://localhost:8088",
            workingDir: "\(NSHomeDirectory())/.ai-context/mcp-crawlkit",
            timeout: 12,
            enabled: true ,
            notes: "Web crawl toolkit (scrape/batch/discover/watch/screenshot). Needs CrawlKit backend at localhost:8088."
        ),
    ]
}

// MARK: - About / Updates tab

struct AboutSettingsTab: View {
    @Environment(SparkleUpdaterService.self) private var updater
    @Environment(ThemeStore.self) private var theme

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("SwiftMaestro")
                    .font(.title)
                    .foregroundStyle(theme.chatText)

                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(appVersion) (\(buildVersion))")
                        .foregroundStyle(.secondary)
                }

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(theme.accent)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Links")
                        .font(.headline)

                    Link("Website — swiftmaestro.com", destination: URL(string: "https://swiftmaestro.com")!)
                    Link("GitHub — WOODSEE-DIGI/SwiftMaestro", destination: URL(string: "https://github.com/WOODSEE-DIGI/SwiftMaestro")!)
                    Link("Git — git.woodsee.com", destination: URL(string: "https://git.woodsee.com")!)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Hints")
                        .font(.headline)

                    Toggle("Show feature tips", isOn: Binding(
                        get: { FeatureTip.tipsEnabled },
                        set: { FeatureTip.tipsEnabled = $0 }
                    ))

                    if FeatureTip.tipsEnabled {
                        Button("Reset all tips") {
                            FeatureTip.resetAll()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(theme.accent)
                    }

                    Text("Small contextual hints appear once when you first use a feature.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.background)
    }
}

// MARK: - Reset to default button

/// Per-panel-group reset: clears that group's overrides so it falls back to
/// the adaptive per-appearance defaults (or a skin's colors when set there).
private struct ResetToGlobalButton: View {
    @Environment(ThemeStore.self) private var theme
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Reset to default", action: action)
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accent)
        }
    }
}
