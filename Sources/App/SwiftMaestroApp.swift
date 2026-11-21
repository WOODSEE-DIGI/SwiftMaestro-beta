import SwiftUI
import SwiftMaestroKit

enum SwiftMaestroDefaultsMigration {
    static func applyIfNeeded() {
        let defaults = UserDefaults.standard
        // The catalog reads this exact key. The previous migration wrote a
        // DIFFERENT, unread key (`models.modelID`) using a Hub name instead of a
        // catalog id, so it never actually took effect.
        let modelKey = "models.selectedModelID"
        let modelMigrationKey = "migration.defaultModel.v3"
        let targetModel = ModelCatalog.defaultModelID
        let legacyDefault = "local-qwen3.5-122b"

        let currentModel = defaults.string(forKey: modelKey)
        if currentModel == nil || currentModel?.isEmpty == true {
            defaults.set(targetModel, forKey: modelKey)
        } else if currentModel == legacyDefault,
                  !defaults.bool(forKey: modelMigrationKey) {
            // One-time: move installs off the old 65GB 122B default (which
            // preloaded a huge model every launch) to the fast MoE default.
            // Gated by a flag so a later deliberate 122B choice is never clobbered.
            defaults.set(targetModel, forKey: modelKey)
        }
        defaults.set(true, forKey: modelMigrationKey)

        purgeMailTrackingStateIfNeeded(defaults: defaults)
    }

    /// One-time purge of the removed mail-tracking feature's leftover state
    /// (the privacy cleanup deleted the code but not its data). The tracking
    /// event store is ARCHIVED, not deleted — it's user data (per-message
    /// open/click history) and the destructive-ops rule requires a recoverable
    /// backup. UserDefaults keys and the dead service's Keychain items go.
    private static func purgeMailTrackingStateIfNeeded(defaults: UserDefaults) {
        let purgeKey = "migration.mailTrackingPurge.v1"
        guard !defaults.bool(forKey: purgeKey) else { return }
        defaults.set(true, forKey: purgeKey)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let trackerDir = appSupport.appendingPathComponent("SwiftMaestro/mailtracker", isDirectory: true)
        if FileManager.default.fileExists(atPath: trackerDir.path) {
            let archiveDir = appSupport.appendingPathComponent(
                "SwiftMaestro/mailtracker-purged-20260814", isDirectory: true)
            try? FileManager.default.moveItem(at: trackerDir, to: archiveDir)
        }

        for key in ["owntrack.autoStartRelay", "owntrack.publicBaseURL",
                    "owntrack.signingSecret.fallback", "appleMail.relayBaseURL"] {
            defaults.removeObject(forKey: key)
        }
        for account in ["owntrack-signing-secret", "owntrack-relay-api-key"] {
            try? KeychainService.delete(account: account)
        }
    }
}

/// Ensures spawned MCP server subprocesses are terminated when the app quits.
/// Without this, every successfully-connected MCP server subprocess is an
/// orphan the moment the app exits — nothing else references it once it's
/// no longer needed. (Servers that fail to connect in the first place are a
/// separate leak, fixed at the source in `MCPClientService.connect(to:)`.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    var mcpService: MCPClientService?
    var whatsAppService: WhatsAppService?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // macOS 26 (Tahoe) crashes on launch when NSToolbar restores archived
        // toolbar state that contains an NSCalendarDate — a relic of the old
        // toolbar item serialization. The crash happens DURING toolbar
        // initialization (before any SwiftUI lifecycle hooks run), so we must
        // purge the stale toolbar configuration from UserDefaults here.
        let defaults = UserDefaults.standard
        let keysToRemove = defaults.dictionaryRepresentation().keys.filter {
            $0.contains("Toolbar") || $0.contains("toolbar")
        }
        for key in keysToRemove {
            defaults.removeObject(forKey: key)
        }

        // Decide BEFORE any window appears whether this launch has first-run
        // dependency install work, so ContentView can present the setup
        // progress sheet instead of the welcome sheet with no flicker — a new
        // user's first experience is a named, live activity feed, never a
        // spinning beachball.
        SetupProgressService.shared.plan()

        // Panel/sheet requests can arrive before any window exists (a file
        // opened via Finder, a tool call), so install the coordinator's
        // notification observers before the first window appears.
        MainActor.assumeIsolated {
            WorkspaceCoordinator.shared.installObserversIfNeeded()
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "excalidraw":
            ExcalidrawStore.shared.pendingOpenFileURL = url
            NotificationCenter.default.post(name: .openWorkspacePanel, object: WorkspacePanelKind.canvas)
            NotificationCenter.default.post(
                name: .excalidrawBoardExternallyModified,
                object: nil,
                userInfo: ["boardURL": url, "shouldOpen": true]
            )
            return true

        case "md", "markdown":
            NotificationCenter.default.post(name: .openWorkspacePanel, object: WorkspacePanelKind.notesMD)
            NotificationCenter.default.post(
                name: .notesOpenFileRequested,
                object: nil,
                userInfo: ["fileURL": url]
            )
            return true

        case "html", "htm":
            NotificationCenter.default.post(name: .openWorkspacePanel, object: WorkspacePanelKind.htmlBuilder)
            SwiftWeaverStore.shared.pendingOpenFileURL = url
            NotificationCenter.default.post(
                name: .swiftWeaverOpenFileRequested,
                object: nil,
                userInfo: ["fileURL": url]
            )
            return true

        case "docx", "doc":
            NotificationCenter.default.post(name: .openWorkspacePanel, object: WorkspacePanelKind.maestroDocs)
            MaestroDocsStore.shared.pendingOpenFileURL = url
            NotificationCenter.default.post(
                name: .maestroDocsOpenFileRequested,
                object: nil,
                userInfo: ["fileURL": url]
            )
            return true

        default:
            return false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After a crash, macOS may restore stale windows from its own state
        // restoration that don't correspond to any live SwiftUI WindowGroup.
        // These phantom windows produce "Invalid window" constraint errors
        // (CDXPackagesSetWindowConstraints) and may overlap the main window
        // without ever reaching a usable layout.
        Task { @MainActor in
            // Wait briefly so the Agents window has time to establish itself
            // as NSApp.mainWindow.
            try? await Task.sleep(for: .milliseconds(300))
            guard let main = NSApp.mainWindow else { return }
            for window in NSApp.windows where window != main {
                // Keep Settings, About, and system-level windows alive.
                guard window.level == .normal else { continue }
                let isSettings = window.title == "Settings"
                let isAbout = window.title == "About"
                // Our floating panel windows are recreated from
                // WorkspaceLayoutState rather than from macOS restoration, so
                // they are never phantoms — keep them.
                let isPanelWindow = window.identifier?.rawValue.hasPrefix(
                    FloatingWindowFrameStore.identifierPrefix) == true
                if !isSettings && !isAbout && !isPanelWindow {
                    window.close()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finalize any in-progress voice note (header flush + duration). The
        // audio data is already on disk; this just makes the WAV well-formed.
        VoiceNotesStore.shared.finalizeForAppQuit()
        // Privacy: wipe WebKit cookies/cache/storage on quit when the user
        // enabled "clear site data on quit" in SwiftBrowser's Privacy popover.
        if UserDefaults.standard.bool(forKey: "browser.clearOnQuit") {
            BrowserPrivacyStore.clearAllSiteDataSync()
        }
        if let mcpService {
            Task { await mcpService.shutdown() }
        }
        // The WhatsApp bridge is a long-running native process (holds the
        // live connection) - same leak risk as MCP servers if nothing stops
        // it on quit, so it gets the same cleanup treatment.
        whatsAppService?.stop()
    }
}

@main
struct SwiftMaestroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var engine = MLXInferenceEngine()
    @State private var catalog = ModelCatalog()
    @State private var workspace = WorkspaceStore()
    @State private var todoStore = TodoStore()
    @State private var osintProfileStore = OSINTProfileStore.shared
    @State private var planStore = PlanStore()
    @State private var messageStore = AgentMessageStore()
    @State private var theme: ThemeStore
    @State private var skinStore: SkinStore
    @State private var whisperService = WhisperKitService.shared

    init() {
        // ACP agent mode: when launched with --acp, run as a headless JSON-RPC
        // agent over stdin/stdout instead of starting the SwiftUI app.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--acp") {
            SwiftMaestroDefaultsMigration.applyIfNeeded()
            let engine = MLXInferenceEngine()
            let catalog = ModelCatalog()
            MaestroTools.engine = engine
            MaestroTools.catalog = catalog
            let agent = ACPAgent(engine: engine, catalog: catalog)
            Task {
                // Warm the FTS memory index in the background so headless agent
                // memory_search calls don't block on the first full-store build.
                await MemorySearchService.shared.warm()
                await agent.run()
                exit(0)
            }
            RunLoop.main.run()
        }

        let theme = ThemeStore()
        _theme = State(wrappedValue: theme)
        _skinStore = State(wrappedValue: SkinStore(theme: theme))

        // Register the global push-to-talk hotkey if the user has configured one.
        // Stream Deck can be programmed to send this key; holding it starts
        // WhisperKit recording, releasing it stops and (with auto-send) submits.
        GlobalHotkeyManager.shared.register(
            keyCode: whisperService.pushToTalkKeyCode,
            service: whisperService
        )
    }
    @State private var visionProxyService = VisionProxyService.shared
    @State private var notesViewModel = NotesViewModel()
    @State private var eventKitStore = EventKitStore()
    @State private var appleNotesService = AppleNotesService()
    @State private var contactsService = ContactsService()

    @State private var kanbanStore = KanbanStore()
    @State private var numbersService = NumbersService()
    @State private var mapsService = AppleMapsService.shared
    @State private var photosService = ApplePhotosService()
    @State private var mailService = AppleMailService.shared
    @State private var whatsAppService = WhatsAppService()
    @State private var discordService = DiscordService()
    @State private var pluginService = PluginService()
    @State private var macroStore = MacroStore()
    @State private var busWorker: BusWorker? = nil
    @State private var sparkleUpdater = SparkleUpdaterService.shared
    @State private var webBrowserStore = WebBrowserStore.shared
    @State private var workspaceLayout = WorkspaceLayoutState.shared
    private let mcpService = MCPClientService()


    var body: some Scene {
        // The launch window: the Agents list plus the toolbar chrome that
        // used to live in the main canvas window. Every other panel opens as
        // a floating window the user can place on any monitor.
        WindowGroup("SwiftMaestro", id: "agents-window") {
            AgentsWindowView(mcpService: mcpService)
                .environment(engine)
                .environment(catalog)
                .environment(visionProxyService)
                .environment(workspace)
                .environment(todoStore)
                .environment(osintProfileStore)
                .environment(planStore)
                .environment(messageStore)
                .environment(theme)
                .environment(skinStore)
                .environment(whisperService)
                .environment(notesViewModel)
                .environment(eventKitStore)
                .environment(appleNotesService)
                .environment(contactsService)
                .environment(kanbanStore)
                .environment(numbersService)
                .environment(mapsService)
                .environment(photosService)
                .environment(mailService)
                .environment(whatsAppService)
                .environment(discordService)
                .environment(pluginService)
                .environment(macroStore)
                .environment(webBrowserStore)

        }
        .defaultSize(width: 300, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            // Window > panel recovery menu. All dynamic lists are computed
            // HERE in the scene body so @Observable tracking rebuilds the
            // menus the moment the layout, agents, plugins, or app-enablement
            // state changes — never inside the Commands value, which SwiftUI
            // would not observe.
            PanelCommands(
                layout: workspaceLayout,
                navigator: workspace.navigator,
                agentGroups: workspace.projectAgentsByCategory(),
                categorizedPanels: AppCategory.allCases.filter { !$0.isHidden }.map { category in
                    (category: category, kinds: AppEnablementStore.shared.visibleKinds(in: category))
                }.filter { !$0.kinds.isEmpty },
                builtInPlugins: AppCategory.builtInPluginKinds.filter {
                    AppEnablementStore.shared.showsBuiltInPlugin($0)
                },
                plugins: pluginService.plugins.filter {
                    AppEnablementStore.shared.showsPlugin($0.id)
                },
                openPanels: Set(workspaceLayout.allOpenPanels),

                panelLayout: PanelLayoutState.shared
            )
        }


        // Standalone, resizable reading window for a single plan. Data-driven so
        // `openWindow(id:value:)` from the Plans browser opens (or fronts) the
        // window for a specific plan. `.contentSize` resizability lets the plan's
        // own ideal size drive the opening dimensions (clamped to the screen).
        WindowGroup("Plan", id: "plan-window", for: PlanWindowID.self) { $target in
            PlanWindowView(target: target)
                .environment(planStore)
                .environment(theme)
        }
        .windowResizability(.contentSize)

        // Floating chat window for any agent. Opens manually from the chat
        // toolbar or automatically when Maestro delegates to a sub-agent.
        WindowGroup("Agent Chat", id: "agent-chat-window", for: AgentChatWindowID.self) { $target in
            AgentChatWindowView(target: target)
                .environment(engine)
                .environment(catalog)
                .environment(visionProxyService)
                .environment(workspace)
                .environment(todoStore)
                .environment(osintProfileStore)
                .environment(planStore)
                .environment(messageStore)
                .environment(theme)
                .environment(whisperService)
                .environment(macroStore)
        }
        .defaultSize(width: 960, height: 720)
        .windowResizability(.contentMinSize)

        // Floating panel windows (Tasks, Terminal, Plans). Opened when the user
        // pops a panel out from the main window's right column.
        WindowGroup("Panel", id: "floating-panel-window", for: FloatingPanelWindowID.self) { $target in
            if let target {
                FloatingPanelWindowView(target: target)
                    .environment(engine)
                    .environment(catalog)
                    .environment(todoStore)
                    .environment(osintProfileStore)
                    .environment(planStore)
                    .environment(theme)
                    .environment(macroStore)
            }
        }
        .defaultSize(width: 380, height: 520)
        .windowResizability(.contentMinSize)

        // Floating window for any top-level workspace panel (agent chat,
        // Notes.md, Apple Notes, Calendar, Reminders, Contacts, Canvas,
        // Kanban). Every panel after the first one the user opens defaults to
        // floating like this — they drag it wherever they like (including a
        // second monitor) and dock it back into the main window via its own
        // "Dock" button whenever they want.
        WindowGroup("Panel", id: "workspace-panel-window", for: WorkspacePanelWindowID.self) { $target in
            if let target {
                WorkspacePanelWindowView(target: target)
                    .environment(engine)
                    .environment(catalog)
                    .environment(visionProxyService)
                    .environment(workspace)
                    .environment(todoStore)
                    .environment(osintProfileStore)
                    .environment(planStore)
                    .environment(messageStore)
                    .environment(theme)
                    .environment(whisperService)
                    .environment(macroStore)
                    .environment(notesViewModel)
                    .environment(eventKitStore)
                    .environment(appleNotesService)
                    .environment(contactsService)
                    .environment(kanbanStore)
                    .environment(numbersService)
                    .environment(mapsService)
                .environment(photosService)
                .environment(mailService)
                .environment(whatsAppService)
                .environment(discordService)
                .environment(pluginService)
                .environment(webBrowserStore)
            }
        }
        .defaultSize(width: 500, height: 700)
        .windowResizability(.contentMinSize)



        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
                .environment(catalog)
                .environment(visionProxyService)
                .environment(workspace)
                .environment(todoStore)
                .environment(osintProfileStore)
                .environment(planStore)
                .environment(messageStore)
                .environment(theme)
                .environment(skinStore)
                .environment(whisperService)
                .environment(macroStore)
                .environment(\.mcpClientService, mcpService)
                // The Settings → Apps tab lists installed plugins, so it needs the
                // same PluginService the main window uses (the single @State instance
                // already populated by loadPlugins() at launch).
                .environment(pluginService)
        }
        .defaultSize(width: 900, height: 960)
        // Settings scenes default to `.contentSize`, which pins the window to the
        // content's size (so it can't be resized). `.contentMinSize` enforces only
        // the content's MINIMUM, letting the user resize the window larger to use
        // available screen space (e.g. see the Appearance preview without scrolling).
        // Menu-bar companion: the recovery path when every panel window is
        // closed, plus the pomodoro controls.
        MenuBarExtra {
            PomodoroMenuBarMenu(store: PomodoroStore.shared) {
                openOrFocusPanel(.pomodoro)
            }
            Divider()
            Button("Show Agents") { openOrFocusPanel(.agents) }
            Button("Show Apps") { openOrFocusPanel(.appLauncher) }
        } label: {
            PomodoroMenuBarLabel(store: PomodoroStore.shared)
        }
        .menuBarExtraStyle(.menu)
        #endif
    }

    /// Menu-bar companion to `PanelCommands.openOrFocus`: open the panel's
    /// floating window, or front it when it is already open.
    private func openOrFocusPanel(_ kind: WorkspacePanelKind) {
        WorkspaceCoordinator.shared.openPanel(kind)
    }
}

// MARK: - Window Menu Panel Commands

/// Window > panel commands: open, reopen, or focus any workspace panel.
/// This is the recovery path when a panel was closed (the ✕ on its tile) or
/// its floating window vanished — previously the only way back was the
/// Agents / Apps Launcher panels, which could themselves be closed with no
/// way back. All dynamic content is snapshotted by the app scene body (which
/// owns the @Observable tracking) and passed in as plain values, so the menus
/// are always current when opened.
private struct PanelCommands: Commands {
    let layout: WorkspaceLayoutState
    let navigator: AgentRecord
    let agentGroups: [(category: AgentCategory, agents: [AgentRecord])]
    let categorizedPanels: [(category: AppCategory, kinds: [WorkspacePanelKind])]
    let builtInPlugins: [WorkspacePanelKind]
    let plugins: [PluginManifest]
    /// Open panel kinds at body-evaluation time — drives the checkmarks.
    let openPanels: Set<WorkspacePanelKind>

    let panelLayout: PanelLayoutState

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The Window menu is installed for the process's whole lifetime, so
        // it is the most reliable place to hand the coordinator an
        // `openWindow` handle: panel-open requests keep working even when
        // every panel window is closed.
        let _ = WorkspaceCoordinator.shared.bindOpenWindow { kind in
            if kind == .agents {
                openWindow(id: "agents-window")
            } else {
                openWindow(id: "workspace-panel-window", value: WorkspacePanelWindowID(kind: kind))
            }
        }

        CommandGroup(before: .windowArrangement) {
            // Recovery-critical chrome first: if these get closed there is no
            // other in-app path back to the navigator or the launcher.
            panelButton(.agents)
                .keyboardShortcut("0", modifiers: .command)
            panelButton(.appLauncher)

            Divider()

            agentChatsMenu
            panelsMenu
            agentSubPanelsMenu

            Divider()

            Button("Reset Window Positions") {
                layout.resetToDefaultLayout()
                FloatingWindowFrameStore.shared.resetAll()
            }

            Divider()
        }

        // Anonymous, user-initiated diagnostic reporting (Help menu). Opens a
        // sheet that previews the exact redacted payload — nothing sends until
        // the user clicks Send (every report is its own act of consent).
        CommandGroup(after: .help) {
            Button("Send Diagnostic Report…") {
                NotificationCenter.default.post(name: .openDiagnosticReport, object: nil)
            }
        }
    }

    // MARK: Agent Chats submenu

    @ViewBuilder
    private var agentChatsMenu: some View {
        Menu("Agent Chats") {
            panelButton(.agentChat(navigator.id), title: navigator.name)
            if !agentGroups.isEmpty {
                Divider()
                ForEach(agentGroups, id: \.category) { group in
                    Section(group.category.displayName) {
                        ForEach(group.agents) { agent in
                            panelButton(.agentChat(agent.id), title: agent.name)
                        }
                    }
                }
            }
        }
    }

    // MARK: Panels submenu

    @ViewBuilder
    private var panelsMenu: some View {
        Menu("Panels") {
            ForEach(categorizedPanels, id: \.category) { group in
                Section(group.category.title) {
                    ForEach(group.kinds, id: \.self) { kind in
                        panelButton(kind)
                    }
                }
            }
            if !builtInPlugins.isEmpty || !plugins.isEmpty {
                Section("Plugins") {
                    ForEach(builtInPlugins, id: \.self) { kind in
                        panelButton(kind)
                    }
                    ForEach(plugins) { manifest in
                        panelButton(.plugin(manifest.id), title: manifest.name, icon: manifest.icon)
                    }
                }
            }
        }
    }

    // MARK: Agent sub-panels (Plans / Tasks)

    /// Toggle visibility of Plans and Macros sub-panels inside agent chats.
    /// These are per-chat side panels managed by PanelLayoutState.
    /// Tasks no longer live in a side panel; they were moved to the composer dock.
    @ViewBuilder
    private var agentSubPanelsMenu: some View {
        Section("Agent Panels") {
            Button {
                withAnimation { panelLayout.toggleVisibility(.plans) }
            } label: {
                Label(
                    panelLayout.hiddenPanels.contains(.plans) ? "Show Plans" : "Hide Plans",
                    systemImage: panelLayout.hiddenPanels.contains(.plans)
                        ? "list.bullet.rectangle" : "list.bullet.rectangle.fill"
                )
            }
            Button {
                withAnimation { panelLayout.toggleVisibility(.macros) }
            } label: {
                Label(
                    panelLayout.hiddenPanels.contains(.macros) ? "Show Macros" : "Hide Macros",
                    systemImage: panelLayout.hiddenPanels.contains(.macros)
                        ? "button.programmable" : "button.programmable.fill"
                )
            }
            Button {
                withAnimation { panelLayout.toggleVisibility(.osintProfile) }
            } label: {
                Label(
                    panelLayout.hiddenPanels.contains(.osintProfile) ? "Show OSINT Profile" : "Hide OSINT Profile",
                    systemImage: panelLayout.hiddenPanels.contains(.osintProfile)
                        ? "person.crop.rectangle.stack" : "person.crop.rectangle.stack.fill"
                )
            }
        }
    }

    // MARK: One menu item

    /// A checkmark replaces the icon while the panel is open; clicking an
    /// open panel focuses it rather than closing it (these are not toggles).
    private func panelButton(
        _ kind: WorkspacePanelKind,
        title: String? = nil,
        icon: String? = nil
    ) -> some View {
        let isOpen = openPanels.contains(kind)
        return Button {
            openOrFocus(kind)
        } label: {
            Label(
                title ?? kind.staticDisplayName ?? "Panel",
                systemImage: isOpen ? "checkmark" : (icon ?? kind.icon)
            )
        }
    }

    // MARK: Open / focus

    /// Open the panel, or front it when it is already open. Delegates to the
    /// coordinator so the Window menu and the notification path share one
    /// code path (and one `openWindow` binding).
    private func openOrFocus(_ kind: WorkspacePanelKind) {
        WorkspaceCoordinator.shared.openPanel(kind)
    }
}
