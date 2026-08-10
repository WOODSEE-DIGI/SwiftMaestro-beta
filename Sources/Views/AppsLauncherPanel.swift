import SwiftUI

/// The movable "Apple Apps / Swift Apps / Plugins" launcher, rendered
/// as a normal tiling panel. Each section is collapsible.
struct AppsLauncherPanel: View {
    @Environment(PluginService.self) private var pluginService
    @Environment(ThemeStore.self) private var theme
    private var workspaceLayout = WorkspaceLayoutState.shared
    private var appEnablement = AppEnablementStore.shared

    /// Titles of the sections the user has collapsed (expanded by default).
    @State private var collapsed: Set<String> = []

    var body: some View {
        FeatureTipPopup(
            key: FeatureTip.panels,
            message: "Open any panel — it tiles to the right by default. Hold Shift to dock below, or Option to float.",
            icon: "sidebar.left"
        ) {
            List {
            // Categories and their apps come from AppCategory (the single source
            // of truth) and are filtered by AppEnablementStore — a disabled
            // category/app hides its row, and a section with no visible apps is
            // omitted entirely so no empty headers linger.
            ForEach(AppCategory.allCases, id: \.self) { category in
                if !category.isHidden {
                    let visible = appEnablement.visibleKinds(in: category)
                    if !visible.isEmpty {
                        collapsibleSection(category.title) {
                            ForEach(visible, id: \.self) { kind in
                                sidebarRow(kind.staticDisplayName ?? kind.themeStorageKey, kind: kind)
                            }
                        }
                    }
                }
            }
            // The Plugins section mixes built-in native panels that behave
            // like plugins to the user (WhatsApp, Discord) with the
            // manifest-driven WKWebView plugins (Bluesky, Mastodon, Patreon).
            let visibleBuiltIns = AppCategory.builtInPluginKinds.filter { appEnablement.showsBuiltInPlugin($0) }
            let visiblePlugins = pluginService.plugins.filter { appEnablement.showsPlugin($0.id) }
            if !visibleBuiltIns.isEmpty || !visiblePlugins.isEmpty {
                collapsibleSection("Plugins") {
                    ForEach(visibleBuiltIns, id: \.self) { kind in
                        sidebarRow(kind.staticDisplayName ?? kind.themeStorageKey, kind: kind)
                    }
                    ForEach(visiblePlugins) { manifest in
                        sidebarRow(manifest.name, kind: .plugin(manifest.id), icon: manifest.icon)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.sidebarBackground)
        }
    }

    /// A section whose rows can be collapsed/expanded by tapping its header.
    @ViewBuilder
    private func collapsibleSection<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            if !collapsed.contains(title) {
                content()
            }
        } header: {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
                }
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: collapsed.contains(title) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func sidebarRow(_ title: String, kind: WorkspacePanelKind, icon: String? = nil) -> some View {
        HStack {
            Label(title, systemImage: icon ?? kind.icon)
                .foregroundStyle(theme.sidebarText)
            Spacer()
            if kind.isStudioApp && !StudioAddon.shared.isAvailable {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if workspaceLayout.isOpen(kind) {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Capture modifier flags NOW (while the click event is still the
            // most recent NSEvent) and pass them through userInfo so the
            // receiver doesn't have to re-read NSEvent.modifierFlags after
            // the modifiers may have been released.
            let flags = NSEvent.modifierFlags
            NotificationCenter.default.post(
                name: .openWorkspacePanel,
                object: kind,
                userInfo: ["modifierFlags": flags]
            )
        }
    }
}
