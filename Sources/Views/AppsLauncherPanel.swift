import SwiftUI

/// The movable "Apple Apps / Swift Apps / Plugins" launcher, rendered
/// as a normal tiling panel. Each section is collapsible.
///
/// **Adaptive layout**: the panel detects its tile dimensions and switches between:
/// - `iconsOnly` (< 56 pt wide) — compact icon rail with tooltips
/// - `iconsWithLabels` (taller than wide) — the standard vertical icon+label list
/// - `horizontalColumns` (wider than tall) — items flow into a horizontal grid
struct AppsLauncherPanel: View {
    @Environment(PluginService.self) private var pluginService
    @Environment(ThemeStore.self) private var theme
    private var workspaceLayout = WorkspaceLayoutState.shared
    private var appEnablement = AppEnablementStore.shared

    /// Titles of the sections the user has collapsed (expanded by default).
    @State private var collapsed: Set<String> = []
    /// Measured panel width — updated via `.background(GeometryReader)` so it
    /// doesn't fight with the content for layout priority (which causes the
    /// resize-bounce bug a raw `AdaptivePanelContainer` GeometryReader would).
    @State private var panelWidth: CGFloat = 200

    /// Tile frame read directly from WorkspaceLayoutState — gives us both
    /// width AND height for orientation detection (the background GeometryReader
    /// only measures content width, not tile height).
    private var tileFrame: CGRect {
        guard let tile = workspaceLayout.canvasTile(containing: .appLauncher) else {
            return .zero
        }
        return tile.frame(in: workspaceLayout.canvasSize)
    }

    private var mode: AdaptivePanelMode {
        AdaptivePanelMode.from(width: panelWidth, height: tileFrame.height)
    }

    var body: some View {
        FeatureTipPopup(
            key: FeatureTip.panels,
            message: "Open any panel — it tiles to the right by default. Hold Shift to dock below, or Option to float.",
            icon: "sidebar.left"
        ) {
            Group {
                switch mode {
                case .iconsOnly:
                    iconsOnlyContent
                case .iconsWithLabels:
                    labelsContent
                case .horizontalColumns:
                    horizontalContent
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: PanelWidthKey.self, value: geo.size.width)
                }
            )
            .onPreferenceChange(PanelWidthKey.self) { width in
                panelWidth = width
            }
        }
    }

    // MARK: - Preference Key

    private struct PanelWidthKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: CGFloat = 200
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    // MARK: - Icons Only (< 56 pt wide)

    private var iconsOnlyContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(allVisibleKinds(), id: \.self) { kind in
                    iconOnlyRow(kind)
                }
                ForEach(AppCategory.builtInPluginKinds.filter { appEnablement.showsBuiltInPlugin($0) }, id: \.self) { kind in
                    iconOnlyRow(kind)
                }
                ForEach(pluginService.plugins.filter { appEnablement.showsPlugin($0.id) }) { manifest in
                    iconOnlyPluginRow(manifest)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .background(theme.sidebarBackground)
    }

    @ViewBuilder
    private func iconOnlyRow(_ kind: WorkspacePanelKind) -> some View {
        let isOpen = workspaceLayout.isOpenOrAnyTerminal(kind)
        Image(systemName: kind.icon)
            .font(.system(size: 24))
            .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { openPanel(kind) }
            .help(kind.staticDisplayName ?? kind.themeStorageKey)
    }

    @ViewBuilder
    private func iconOnlyPluginRow(_ manifest: PluginManifest) -> some View {
        let isOpen = workspaceLayout.isOpen(.plugin(manifest.id))
        Image(systemName: manifest.icon)
            .font(.system(size: 24))
            .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { openPanel(.plugin(manifest.id)) }
            .help(manifest.name)
    }

    // MARK: - Icons + Labels (taller than wide) — standard vertical list

    private var labelsContent: some View {
        List {
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
            } else if workspaceLayout.isOpenOrAnyTerminal(kind) {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            NotificationCenter.default.post(
                name: .openWorkspacePanel,
                object: kind,
                userInfo: ["modifierFlags": flags]
            )
        }
    }

    // MARK: - Horizontal Columns (wider than tall) — grid of icon+label cells

    private var horizontalContent: some View {
        let allItems = buildHorizontalItems()
        // Adaptive columns: ~120pt per column, filling available width
        let columnCount = max(1, Int((panelWidth / 120).rounded(.down)))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: columnCount)

        return ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(allItems) { item in
                    horizontalItem(item)
                }
            }
            .padding(10)
        }
        .background(theme.sidebarBackground)
    }

    private struct HorizontalItem: Identifiable {
        let id = UUID()
        let kind: WorkspacePanelKind
        let name: String
        let icon: String
    }

    private func buildHorizontalItems() -> [HorizontalItem] {
        var items: [HorizontalItem] = []
        for category in AppCategory.allCases where !category.isHidden {
            for kind in appEnablement.visibleKinds(in: category) {
                items.append(HorizontalItem(kind: kind, name: kind.staticDisplayName ?? kind.themeStorageKey, icon: kind.icon))
            }
        }
        for kind in AppCategory.builtInPluginKinds where appEnablement.showsBuiltInPlugin(kind) {
            items.append(HorizontalItem(kind: kind, name: kind.staticDisplayName ?? kind.themeStorageKey, icon: kind.icon))
        }
        for manifest in pluginService.plugins where appEnablement.showsPlugin(manifest.id) {
            items.append(HorizontalItem(kind: .plugin(manifest.id), name: manifest.name, icon: manifest.icon))
        }
        return items
    }

    @ViewBuilder
    private func horizontalItem(_ item: HorizontalItem) -> some View {
        let isOpen = workspaceLayout.isOpen(item.kind)
        VStack(spacing: 4) {
            Image(systemName: item.icon)
                .font(.system(size: 22))
                .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
                .frame(width: 28, height: 28)
            Text(item.name)
                .font(.caption)
                .foregroundStyle(theme.sidebarText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { openPanel(item.kind) }
    }

    // MARK: - Helpers

    private func allVisibleKinds() -> [WorkspacePanelKind] {
        AppCategory.allCases.flatMap { category in
            appEnablement.visibleKinds(in: category)
        }
    }

    private func openPanel(_ kind: WorkspacePanelKind) {
        let flags = NSEvent.modifierFlags
        NotificationCenter.default.post(
            name: .openWorkspacePanel,
            object: kind,
            userInfo: ["modifierFlags": flags]
        )
    }
}
