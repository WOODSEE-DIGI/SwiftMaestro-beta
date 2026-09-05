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

    /// User-selected view mode for the Apps panel. `automatic` follows the tile
    /// shape; `list` and `icon` force the corresponding layout.
    enum ViewMode: String, CaseIterable {
        case automatic
        case list
        case icon

        var icon: String {
            switch self {
            case .automatic: return "arrow.left.arrow.right"
            case .list: return "list.bullet"
            case .icon: return "square.grid.2x2"
            }
        }

        var title: String {
            switch self {
            case .automatic: return "Auto"
            case .list: return "List"
            case .icon: return "Icons"
            }
        }
    }

    /// Persisted view mode preference for the Apps panel.
    @AppStorage("appsLauncher.viewMode") private var viewMode: ViewMode = .automatic

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

    private var resolvedMode: AdaptivePanelMode {
        switch viewMode {
        case .automatic:
            return AdaptivePanelMode.from(width: panelWidth, height: tileFrame.height)
        case .list:
            return panelWidth < 56 ? .iconsOnly : .iconsWithLabels
        case .icon:
            return panelWidth < 56 ? .iconsOnly : .horizontalColumns
        }
    }

    /// The header toolbar shown inside `WorkspacePanelContainer` for this panel.
    var headerToolbar: some View {
        Picker("View", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
        .help("Switch between automatic, list, and icon views")
    }

    var body: some View {
        FeatureTipPopup(
            key: FeatureTip.panels,
            message: "Open any panel — it tiles to the right by default. Hold Shift to dock below, or Option to float.",
            icon: "sidebar.left"
        ) {
            Group {
                switch resolvedMode {
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
        ZStack(alignment: .topTrailing) {
            Image(systemName: kind.icon)
                .font(.system(size: 24))
                .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
                .frame(width: 44, height: 44)
            if kind.appCategory == .swiftApps {
                    betaDot
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { openPanel(kind) }
        .help(kind.staticDisplayName ?? kind.themeStorageKey)
    }

    private var betaDot: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .offset(x: 2, y: -2)
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
        HStack(spacing: 8) {
            Label(title, systemImage: icon ?? kind.icon)
                .foregroundStyle(theme.sidebarText)
            if kind.appCategory == .swiftApps {
                BetaTag()
            }
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

    // MARK: - Horizontal Columns (wider than tall) — categorized icon+label grid

    private var horizontalContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(AppCategory.allCases, id: \.self) { category in
                    if !category.isHidden {
                        let visible = appEnablement.visibleKinds(in: category)
                        if !visible.isEmpty {
                            horizontalSection(title: category.title, kinds: visible)
                        }
                    }
                }
                let visibleBuiltIns = AppCategory.builtInPluginKinds.filter { appEnablement.showsBuiltInPlugin($0) }
                let visiblePlugins = pluginService.plugins.filter { appEnablement.showsPlugin($0.id) }
                if !visibleBuiltIns.isEmpty || !visiblePlugins.isEmpty {
                    horizontalSection(title: "Plugins", kinds: visibleBuiltIns) {
                        ForEach(visiblePlugins) { manifest in
                            gridCell(kind: .plugin(manifest.id), name: manifest.name, icon: manifest.icon)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(theme.sidebarBackground)
    }

    /// One category section laid out as an adaptive grid. Items flow into as
    /// many equal-width columns as fit, then wrap to the next row. This keeps
    /// apps evenly distributed while respecting the panel width.
    @ViewBuilder
    private func horizontalSection(
        title: String,
        kinds: [WorkspacePanelKind],
        @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 78, maximum: 110), spacing: 8)],
                alignment: .center,
                spacing: 10
            ) {
                ForEach(kinds, id: \.self) { kind in
                    gridCell(
                        kind: kind,
                        name: kind.staticDisplayName ?? kind.themeStorageKey,
                        icon: kind.icon)
                }
                extra()
            }
        }
    }

    @ViewBuilder
    private func gridCell(kind: WorkspacePanelKind, name: String, icon: String) -> some View {
        let isOpen = workspaceLayout.isOpenOrAnyTerminal(kind)
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
                    .frame(width: 28, height: 28)
                if kind.appCategory == .swiftApps {
                    betaDot
                }
            }
            HStack(spacing: 2) {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(theme.sidebarText)
                    .lineLimit(1)
                if kind.appCategory == .swiftApps {
                    BetaTag()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(Rectangle())
        .onTapGesture { openPanel(kind) }
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

// MARK: - Beta Tag

struct BetaTag: View {
    var body: some View {
        Text("Beta")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(Color.orange)
            )
            .fixedSize()
    }
}
