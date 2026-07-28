import SwiftUI

/// The movable "Apple Apps / Swift Apps / Plugins" launcher used when the
/// lower sidebar section is moved into the workspace grid.
struct AppsLauncherPanel: View {
    @Environment(PluginService.self) private var pluginService
    @Environment(ThemeStore.self) private var theme
    private var workspaceLayout = WorkspaceLayoutState.shared

    var body: some View {
        List {
            Section {
                sidebarRow("Apple Notes", kind: .appleNotes)
                sidebarRow("Calendar", kind: .calendar)
                sidebarRow("Reminders", kind: .reminders)
                sidebarRow("Contacts", kind: .contacts)
                sidebarRow("Numbers", kind: .numbers)
                sidebarRow("Maps", kind: .maps)
                sidebarRow("Photos", kind: .photos)
            } header: {
                Text("Apple Apps")
            }
            Section {
                sidebarRow("Cameras", kind: .tethering)
                sidebarRow("Stream Ingest", kind: .streamIngest)
                sidebarRow("Broadcast", kind: .broadcast)
                sidebarRow("Stream Mixer", kind: .streamMixer)
                sidebarRow("NDI Browser", kind: .ndiBrowser)
                sidebarRow("Color Adjustments", kind: .colorAdjustments)
                sidebarRow("Scenes", kind: .scenes)
            } header: {
                Text("Studio")
            }
            Section {
                sidebarRow("WhatsApp", kind: .whatsapp)
                sidebarRow("Discord", kind: .discord)
                sidebarRow("Bus Monitor", kind: .busMonitor)
                sidebarRow("Audio Control", kind: .audioControl)
                sidebarRow("Notes.md", kind: .notesMD)
                sidebarRow("Canvas", kind: .canvas)
                sidebarRow("Kanban", kind: .kanban)
                sidebarRow("Terminal", kind: .terminal)
            } header: {
                Text("Swift Apps")
            }
            if !pluginService.plugins.isEmpty {
                Section {
                    ForEach(pluginService.plugins) { manifest in
                        sidebarRow(manifest.name, kind: .plugin(manifest.id), icon: manifest.icon)
                    }
                } header: {
                    Text("Plugins")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(theme.sidebarOverridden ? .hidden : .automatic)
        .background(theme.sidebarOverridden ? theme.sidebarBackground : Color.clear)
    }

    private func sidebarRow(_ title: String, kind: WorkspacePanelKind, icon: String? = nil) -> some View {
        HStack {
            Label(title, systemImage: icon ?? kind.icon)
                .foregroundStyle(theme.sidebarText)
            Spacer()
            if workspaceLayout.isOpen(kind) {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NotificationCenter.default.post(name: .openWorkspacePanel, object: kind)
        }
    }
}
