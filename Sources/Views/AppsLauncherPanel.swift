import SwiftUI

/// The movable "Apple Apps / Swift Apps / Plugins" launcher, rendered as a
/// floating workspace panel. Each section is collapsible.
///
/// **Adaptive layout**: the panel detects its own dimensions and switches between:
/// - `iconsOnly` (< 56 pt wide) — compact icon rail with tooltips
/// - `iconsWithLabels` (taller than wide) — the standard vertical icon+label list
/// - `horizontalColumns` (wider than tall) — items flow into a horizontal grid
struct AppsLauncherPanel: View {
    @Environment(PluginService.self) private var pluginService
    @Environment(ThemeStore.self) private var theme
    private var workspaceLayout = WorkspaceLayoutState.shared
    private var appEnablement = AppEnablementStore.shared

    /// User-selected view mode for the Apps panel. `automatic` follows the panel
    /// shape; `list`, `grid`, and `icon` force the corresponding layout.
    enum ViewMode: String, CaseIterable {
        case automatic
        case list
        case grid
        case icon

        var icon: String {
            switch self {
            case .automatic: return "arrow.left.arrow.right"
            case .list: return "list.bullet"
            case .grid: return "square.grid.3x3"
            case .icon: return "rectangle.split.1x2"
            }
        }

        var title: String {
            switch self {
            case .automatic: return "Auto"
            case .list: return "List"
            case .grid: return "Grid"
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
    /// Measured panel height — see `tileFrame`.
    @State private var panelHeight: CGFloat = 600

    /// Measured panel bounds — gives us both width AND height for orientation
    /// detection. With the canvas gone there is no tile to read, so the panel
    /// measures itself.
    private var tileFrame: CGRect {
        CGRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
    }

    private var resolvedMode: AdaptivePanelMode {
        switch viewMode {
        case .automatic:
            return AdaptivePanelMode.from(width: panelWidth, height: tileFrame.height)
        case .list:
            return panelWidth < 56 ? .iconsOnly : .iconsWithLabels
        case .grid:
            return .horizontalColumns
        case .icon:
            return .iconsOnly
        }
    }

    /// The header toolbar shown for this panel in its floating window.
    var headerToolbar: some View {
        Picker("View", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .help("Switch between automatic, list, grid, and icon views")
    }

    var body: some View {
        FeatureTipPopup(
            key: FeatureTip.panels,
            message: "Open any panel — it tiles to the right by default. Hold Shift to dock below, or Option to float.",
            icon: "sidebar.left"
        ) {
            Group {
                if viewMode == .icon {
                    compactIconGridContent
                } else {
                    switch resolvedMode {
                    case .iconsOnly:
                        iconsOnlyContent
                    case .iconsWithLabels:
                        labelsContent
                    case .horizontalColumns:
                        horizontalContent
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: PanelWidthKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(PanelWidthKey.self) { size in
                panelWidth = size.width
                panelHeight = size.height
            }
            .onAppear {
                migrateViewModeIfNeeded()
            }
        }
    }

    /// One-time migration: the Apps launcher used to default to the vertical
    /// list. Switch existing installs to the new horizontal grid so the
    /// redesign is visible on next open. Users can still switch back manually.
    private func migrateViewModeIfNeeded() {
        let key = "appsLauncher.viewMode.migratedToGridV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        viewMode = .grid
        UserDefaults.standard.set(true, forKey: key)
    }

    // MARK: - Preference Key

    private struct PanelWidthKey: PreferenceKey {
        nonisolated(unsafe) static var defaultValue: CGSize = CGSize(width: 200, height: 600)
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
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
                ForEach(craftApps) { app in
                    craftIconOnlyRow(app)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
        .background(theme.sidebarBackground)
    }

    // MARK: - Compact Icon Grid (explicit "Icons" view mode)

    /// A dense grid of icons with no labels. Used when the user explicitly
    /// selects "Icons" from the view-mode picker to make the Apps window as
    /// small as possible while keeping every app one click away.
    private var compactIconGridContent: some View {
        GeometryReader { geo in
            let padding: CGFloat = 12
            let iconSize: CGFloat = 28
            let cellSize: CGFloat = 34
            let spacing: CGFloat = 4
            let columns = max(1, Int((geo.size.width - padding * 2 + spacing) / (cellSize + spacing)))

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cellSize), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(allVisibleKinds(), id: \.self) { kind in
                        compactIconCell(kind, size: iconSize)
                    }
                    ForEach(AppCategory.builtInPluginKinds.filter { appEnablement.showsBuiltInPlugin($0) }, id: \.self) { kind in
                        compactIconCell(kind, size: iconSize)
                    }
                    ForEach(pluginService.plugins.filter { appEnablement.showsPlugin($0.id) }) { manifest in
                        compactPluginIconCell(manifest, size: iconSize)
                    }
                    ForEach(craftApps) { app in
                        compactCraftIconCell(app, size: iconSize)
                    }
                }
                .padding(padding)
                .frame(minWidth: geo.size.width, alignment: .center)
            }
        }
        .background(theme.sidebarBackground)
    }

    @ViewBuilder
    private func compactIconCell(_ kind: WorkspacePanelKind, size: CGFloat) -> some View {
        let isOpen = workspaceLayout.isOpenOrAnyTerminal(kind)
        ZStack(alignment: .topTrailing) {
            Image(systemName: kind.icon)
                .font(.system(size: size))
                .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
                .frame(width: cellSize(for: size), height: cellSize(for: size))
            if kind.appCategory == .swiftApps {
                betaDot
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openPanel(kind) }
        .help(kind.staticDisplayName ?? kind.themeStorageKey)
    }

    @ViewBuilder
    private func compactPluginIconCell(_ manifest: PluginManifest, size: CGFloat) -> some View {
        let isOpen = workspaceLayout.isOpen(.plugin(manifest.id))
        Image(systemName: manifest.icon)
            .font(.system(size: size))
            .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
            .frame(width: cellSize(for: size), height: cellSize(for: size))
            .contentShape(Rectangle())
            .onTapGesture { openPanel(.plugin(manifest.id)) }
            .help(manifest.name)
    }

    @ViewBuilder
    private func compactCraftIconCell(_ app: CraftApp, size: CGFloat) -> some View {
        craftIcon(app, size: size)
            .frame(width: cellSize(for: size), height: cellSize(for: size))
            .contentShape(Rectangle())
            .onTapGesture { CraftAppLauncher.shared.launch(app) }
            .help(app.name)
    }

    private func cellSize(for iconSize: CGFloat) -> CGFloat {
        iconSize + 6
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
            .frame(width: 6, height: 6)
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

    @ViewBuilder
    private func craftIconOnlyRow(_ app: CraftApp) -> some View {
        craftIcon(app, size: 30)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture { CraftAppLauncher.shared.launch(app) }
            .help(app.name)
    }

    /// The desktop app's own icon when installed, generic fallback before
    /// install (SF Symbols can't render an NSImage, hence the switch).
    @ViewBuilder
    private func craftIcon(_ app: CraftApp, size: CGFloat) -> some View {
        if let icon = CraftAppLauncher.icon(for: app) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "paintpalette")
                .font(.system(size: size))
                .frame(width: size, height: size)
        }
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
            if !craftApps.isEmpty {
                collapsibleSection("ArtCraft Apps") {
                    ForEach(craftApps) { app in
                        craftRow(app)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.sidebarBackground)
    }

    /// A Craft app row — shows its real icon and a hint that the app opens
    /// as its own window (outside the workspace canvas).
    private func craftRow(_ app: CraftApp) -> some View {
        HStack(spacing: 8) {
            craftIcon(app, size: 18)
            Text(app.name)
                .foregroundStyle(theme.sidebarText)
            Spacer()
            Image(systemName: "arrow.up.forward.app")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("Opens \(app.name) as its own window")
        }
        .contentShape(Rectangle())
        .onTapGesture { CraftAppLauncher.shared.launch(app) }
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

    // MARK: - Horizontal Columns (wider than tall) — categorized wrapping grid

    /// A unified item type for the horizontal grid so each category can render
    /// a mix of panel kinds, plugins, and Craft apps.
    private enum LauncherGridItem: Identifiable {
        case kind(WorkspacePanelKind)
        case plugin(PluginManifest)
        case craft(CraftApp)

        var id: String {
            switch self {
            case .kind(let k): return k.storageKey
            case .plugin(let p): return "plugin:\(p.id)"
            case .craft(let c): return "craft:\(c.id)"
            }
        }
    }

    /// Category sections in display order.
    private var gridSections: [(title: String, items: [LauncherGridItem])] {
        var sections: [(title: String, items: [LauncherGridItem])] = []
        for category in AppCategory.allCases where !category.isHidden {
            let kinds = appEnablement.visibleKinds(in: category)
            if !kinds.isEmpty {
                sections.append((category.title, kinds.map { .kind($0) }))
            }
        }
        let visibleBuiltIns = AppCategory.builtInPluginKinds.filter { appEnablement.showsBuiltInPlugin($0) }
        let visiblePlugins = pluginService.plugins.filter { appEnablement.showsPlugin($0.id) }
        if !visibleBuiltIns.isEmpty || !visiblePlugins.isEmpty {
            var items: [LauncherGridItem] = visibleBuiltIns.map { .kind($0) }
            items.append(contentsOf: visiblePlugins.map { .plugin($0) })
            sections.append(("Plugins", items))
        }
        if !craftApps.isEmpty {
            sections.append(("ArtCraft Apps", craftApps.map { .craft($0) }))
        }
        return sections
    }

    private var horizontalContent: some View {
        GeometryReader { geo in
            let padding: CGFloat = 20
            let baseSectionSpacing: CGFloat = 24
            let itemWidth: CGFloat = 150
            let itemHeight: CGFloat = 36
            let rowSpacing: CGFloat = 2
            let columnSpacing: CGFloat = 12
            let headerHeight: CGFloat = 22
            let narrowThreshold: CGFloat = 600
            let availableHeight = max(itemHeight, geo.size.height - padding * 2 - headerHeight)

            if geo.size.width < narrowThreshold {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: baseSectionSpacing) {
                        ForEach(gridSections, id: \.title) { section in
                            singleColumnSection(
                                title: section.title,
                                items: section.items,
                                itemWidth: itemWidth
                            )
                        }
                    }
                    .padding(padding)
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
            } else {
                let sectionWidths = gridSections.map {
                    gridWidth(
                        for: $0.items,
                        availableHeight: availableHeight,
                        itemWidth: itemWidth,
                        itemHeight: itemHeight,
                        rowSpacing: rowSpacing,
                        columnSpacing: columnSpacing
                    )
                }
                let naturalWidth = sectionWidths.reduce(0, +)
                    + baseSectionSpacing * CGFloat(max(0, gridSections.count - 1))
                let availableWidth = geo.size.width - padding * 2
                let extraWidth = max(0, availableWidth - naturalWidth)
                let adjustedSectionSpacing = gridSections.count > 1
                    ? baseSectionSpacing + extraWidth / CGFloat(gridSections.count - 1)
                    : baseSectionSpacing

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: adjustedSectionSpacing) {
                        ForEach(gridSections, id: \.title) { section in
                            categoryGrid(
                                title: section.title,
                                items: section.items,
                                availableHeight: availableHeight,
                                itemWidth: itemWidth,
                                itemHeight: itemHeight,
                                rowSpacing: rowSpacing,
                                columnSpacing: columnSpacing
                            )
                        }
                    }
                    .padding(padding)
                    .frame(minWidth: max(availableWidth, naturalWidth), alignment: .topLeading)
                }
            }
        }
        .background(theme.sidebarBackground)
    }

    /// The natural width of a category grid given the available height.
    private func gridWidth(
        for items: [LauncherGridItem],
        availableHeight: CGFloat,
        itemWidth: CGFloat,
        itemHeight: CGFloat,
        rowSpacing: CGFloat,
        columnSpacing: CGFloat
    ) -> CGFloat {
        let maxRows = max(1, Int((availableHeight + rowSpacing) / (itemHeight + rowSpacing)))
        let numColumns = max(1, Int(ceil(Double(items.count) / Double(maxRows))))
        return CGFloat(numColumns) * itemWidth + CGFloat(max(0, numColumns - 1)) * columnSpacing
    }

    @ViewBuilder
    private func singleColumnSection(
        title: String,
        items: [LauncherGridItem],
        itemWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    gridItemView(item, width: itemWidth)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryGrid(
        title: String,
        items: [LauncherGridItem],
        availableHeight: CGFloat,
        itemWidth: CGFloat,
        itemHeight: CGFloat,
        rowSpacing: CGFloat,
        columnSpacing: CGFloat
    ) -> some View {
        let maxRows = max(1, Int((availableHeight + rowSpacing) / (itemHeight + rowSpacing)))
        let numColumns = max(1, Int(ceil(Double(items.count) / Double(maxRows))))
        let gridWidth = CGFloat(numColumns) * itemWidth + CGFloat(max(0, numColumns - 1)) * columnSpacing

        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(itemWidth), spacing: columnSpacing), count: numColumns),
                spacing: rowSpacing
            ) {
                ForEach(items) { item in
                    gridItemView(item, width: itemWidth)
                }
            }
            .frame(width: gridWidth, alignment: .topLeading)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func gridItemView(_ item: LauncherGridItem, width: CGFloat) -> some View {
        switch item {
        case .kind(let kind): gridCell(kind: kind, width: width)
        case .plugin(let manifest): pluginGridCell(manifest, width: width)
        case .craft(let app): craftGridCell(app, width: width)
        }
    }

    @ViewBuilder
    private func gridCell(kind: WorkspacePanelKind, width: CGFloat) -> some View {
        let isOpen = workspaceLayout.isOpenOrAnyTerminal(kind)
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: kind.icon)
                    .font(.system(size: 24))
                    .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
                    .frame(width: 28, height: 28)
                if kind.appCategory == .swiftApps {
                    betaDot
                }
            }
            HStack(spacing: 5) {
                Text(kind.staticDisplayName ?? kind.themeStorageKey)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.sidebarText)
                    .lineLimit(1)
                if kind.appCategory == .swiftApps {
                    BetaTag()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onTapGesture { openPanel(kind) }
    }

    @ViewBuilder
    private func pluginGridCell(_ manifest: PluginManifest, width: CGFloat) -> some View {
        let isOpen = workspaceLayout.isOpen(.plugin(manifest.id))
        HStack(spacing: 10) {
            Image(systemName: manifest.icon)
                .font(.system(size: 24))
                .foregroundStyle(isOpen ? theme.accent : theme.sidebarText)
                .frame(width: 28, height: 28)
            Text(manifest.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.sidebarText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onTapGesture { openPanel(.plugin(manifest.id)) }
    }

    @ViewBuilder
    private func craftGridCell(_ app: CraftApp, width: CGFloat) -> some View {
        HStack(spacing: 10) {
            craftIcon(app, size: 28)
            HStack(spacing: 5) {
                Text(app.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.sidebarText)
                    .lineLimit(1)
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .onTapGesture { CraftAppLauncher.shared.launch(app) }
        .help("Opens \(app.name) as its own window")
    }

    // MARK: - Helpers

    private func allVisibleKinds() -> [WorkspacePanelKind] {
        AppCategory.allCases.flatMap { category in
            appEnablement.visibleKinds(in: category)
        }
    }

    /// Fetched Craft apps that should appear in the "ArtCraft Apps" section.
    /// Data-driven like the Plugins section (no WorkspacePanelKind cases) —
    /// rows launch the desktop app as its own window instead of opening a
    /// workspace panel.
    private var craftApps: [CraftApp] {
        CraftAppCatalog.launcherApps.filter { appEnablement.showsCraftApp($0.id) }
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
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(Color.orange)
            )
            .fixedSize()
    }
}
