import SwiftUI

/// Resolves a `WorkspacePanelKind` to its actual content view. Shared between
/// the docked grid (`ContentView`) and floating panel windows
/// (`WorkspacePanelWindowView`) so both render identically and neither
/// duplicates this switch.
struct WorkspacePanelContentView: View {
    let kind: WorkspacePanelKind

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(NotesViewModel.self) private var notesViewModel
    @Environment(PluginService.self) private var pluginService
    @Environment(DiscordService.self) private var discordService

    var body: some View {
        // Studio add-on panels render a locked placeholder until the add-on is
        // enabled (Settings → Add-ons). Everything else resolves normally.
        if kind.isStudioApp && !StudioAddon.shared.isAvailable {
            StudioAddonLockedView()
        } else {
            switch kind {
        case .notesMD:
            NotesView(viewModel: notesViewModel)
        case .appleNotes:
            AppleNotesView()
        case .calendar:
            CalendarView()
        case .reminders:
            RemindersView()
        case .contacts:
            ContactsView()
        case .canvas:
            if #available(macOS 26.0, *) {
                CanvasView()
            } else {
                CanvasFallbackView()
            }
        case .kanban:
            KanbanView()
        case .numbers:
            NumbersView()
        case .maps:
            MapsView()
        case .photos:
            PhotosView()
        case .mail:
            MailView()
        case .whatsapp:
            WhatsAppView()
        case .discord:
            DiscordView()
        case .plugin(let id):
            if let manifest = pluginService.manifest(id: id) {
                PluginPanelView(manifest: manifest)
            } else {
                ContentUnavailableView(
                    "Plugin Not Found",
                    systemImage: "puzzlepiece.extension",
                    description: Text("No plugin with id \"\(id)\" is currently installed.")
                )
            }
        case .terminal:
            TerminalView()
        case .busMonitor:
            BusMonitorView()
        case .audioControl:
            AudioControlView()
        case .tethering:
            TetheringView()
        case .streamIngest:
            StreamIngestView()
        case .broadcast:
            BroadcastView()
        case .streamMixer:
            StreamMixerView()
        case .ndiBrowser:
            NDIBrowserView()
        case .colorAdjustments:
            ColorAdjustmentsView()
        case .scenes:
            StudioSceneView()
        case .agentChat(let id):
            if let agent = workspace.agent(id: id), let cache = ChatViewModelCache.shared {
                ChatView(vm: cache.viewModel(
                    for: agent,
                    projectName: workspace.projectName(for: agent)))
                    .id(agent.id)
            } else {
                ContentUnavailableView(
                    "Agent Not Found",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("This agent no longer exists")
                )
            }
        case .agents:
            AgentsPanelView()
        case .appLauncher:
            AppsLauncherPanel()
        case .webBrowser:
            WebBrowserPanelView()
        case .damBrowser:
            DAMBrowserView()
        case .maestroDocs:
            MaestroDocsView()
        case .maestroBooks:
            MaestroBooksView()
        case .maestroDB:
            MaestroDBView()
        case .overlayBuilder:
            OverlayBuilderView()
        case .backup:
            BackupStatusPanel()
        case .voiceNotes:
            VoiceNotesPanel()
        }
        }
    }
}
