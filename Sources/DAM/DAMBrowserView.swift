import AppKit
import SwiftUI
import GRDB
import UniformTypeIdentifiers

// MARK: - MaestroDAM Browser View
//
// Workspace tabs under the toolbar (order: Home, Metadata, Edit, Output):
//   Home     — Folders tree | thumbnail grid | Preview + File Properties
//   Metadata — Folders+Metadata column | sortable list; two persisted view
//              modes: full-page list, or a large selection preview above the
//              list (AI tagging lives in the metadata panel)
//   Edit / Output — see DAMOutputWorkflow.swift
//
// Side panels are user-resizable via PanelResizeHandle (widths persisted in
// @AppStorage); the preview image scales with the panel width using the
// asset's aspect ratio. Renders identically docked or floating via
// `WorkspacePanelContentView`.

struct DAMBrowserView: View {

    @State private var viewModel = DAMViewModel()
    @AppStorage("dam.showFolderTree") private var showFolderTree = true
    @AppStorage("dam.showPreviewPanel") private var showPreviewPanel = true
    @AppStorage("dam.treeWidth") private var treeWidth: Double = 240
    @AppStorage("dam.previewWidth") private var previewWidth: Double = 300
    @AppStorage("dam.metaSideWidth") private var metaSideWidth: Double = 320
    @AppStorage("dam.catalogSectionExpanded") private var catalogSectionExpanded = true
    @AppStorage("dam.volumesSectionExpanded") private var volumesSectionExpanded = true
    @AppStorage("dam.volumesSectionHeight") private var volumesSectionHeight: Double = 160
    /// Metadata workspace viewing option: full-page list, or a large preview
    /// of the selected image above the list (persisted across launches).
    @AppStorage("dam.metadataViewMode") private var metadataViewMode: MetadataViewMode = .list

    /// Multi-selected folder paths for drag-and-drop operations.
    @State private var selectedFolderPaths: Set<String> = []
    /// Paths currently highlighted as drop targets.
    @State private var dropTargetedPaths: Set<String> = []

    /// Local spacebar monitor for the Finder-style Quick Look preview panel.
    @State private var quickLookMonitor: Any?

    @State private var healthWarnings: [DAMVolume] = []
    @State private var isInitialLoading = true
    @State private var loadingStep = "Initializing…"
    @State private var showingCollectionSheet = false
    @State private var editingCollection: DAMCollection? = nil
    @State private var newCollectionName = ""
    @State private var newCollectionKind: DAMCollection.Kind = .manual
    @State private var newCollectionParentID: Int64?
    @State private var showingOffloadSheet = false
    @State private var appLoadStartDate = Date()
    @State private var quickCropAsset: DAMAsset? = nil
    @State private var isPreparingShare = false
    @State private var shareProgressDone = 0
    @State private var shareProgressTotal = 0

    // Smart predicate sheet state
    @State private var predicateQuery = ""
    @State private var predicateTags = ""
    @State private var predicateMinRating = 0
    @State private var predicateFileType = ""
    @State private var predicateFlagRaw: String = ""
    @State private var predicateTagColor: Int?
    @State private var predicateHasAIKeywords = false
    @State private var predicateHasXattrKeywords = false

    /// Home workspace viewing options.
    @AppStorage("dam.homeViewMode") private var homeViewMode: HomeViewMode = .browser

    private enum HomeViewMode: String, CaseIterable {
        case browser = "browser"
        case statistics = "statistics"
        case storageMap = "storageMap"
        case duplicates = "duplicates"

        var label: String {
            switch self {
            case .browser: return "Browser"
            case .statistics: return "Statistics"
            case .storageMap: return "Storage Map"
            case .duplicates: return "Duplicates"
            }
        }

        var icon: String {
            switch self {
            case .browser: return "square.grid.2x2"
            case .statistics: return "chart.bar"
            case .storageMap: return "externaldrive.badge.icloud"
            case .duplicates: return "doc.on.doc"
            }
        }
    }

    /// Metadata workspace viewing options.
    private enum MetadataViewMode: String {
        case list, preview
    }

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WorkspaceTabBar(viewModel: viewModel)
            Divider()
            workspaceContent
                .overlay {
                    if isInitialLoading {
                        retroLoadingOverlay
                    }
                    if isPreparingShare {
                        sharePreparationOverlay
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $quickCropAsset) { asset in
            DAMQuickCropSheet(asset: asset) { quickCropAsset = nil }
        }
        .task {
            appLoadStartDate = Date()
            isInitialLoading = true
            loadingStep = "Starting volume monitor…"
            Task { await DAMVolumeStore.shared.startMonitoring() }

            loadingStep = "Loading folder tree…"
            async let tree = viewModel.refreshFolderTree()

            loadingStep = "Loading asset grid…"
            async let reload = viewModel.reload()

            _ = await (reload, tree)

            loadingStep = "Starting background enrichment…"
            viewModel.startBackgroundEnrichment()

            isInitialLoading = false

            if let path = UserDefaults.standard.string(forKey: "crm.pendingDAMAssetPath") {
                UserDefaults.standard.removeObject(forKey: "crm.pendingDAMAssetPath")
                await viewModel.revealAsset(atPath: path)
            }
        }
        .onChange(of: viewModel.selectedFolder) { _, newValue in
            if newValue == nil { selectedFolderPaths.removeAll() }
        }
        .onChange(of: viewModel.selectedCollectionID) { _, _ in
            selectedFolderPaths.removeAll()
        }
        .onAppear {
            quickLookMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
                guard event.keyCode == 49 else { return event }
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [.numericPad, .function]) else { return event }
                // Don’t steal spacebar while the user is typing in any text field
                // (keyword editor, search box, rename sheets, etc.).
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                guard let viewModel, viewModel.selection.count == 1,
                      let asset = viewModel.assets.first(where: { $0.id == viewModel.selection.first }),
                      FileManager.default.fileExists(atPath: asset.path)
                else { return event }
                DAMQuickLookPanelController.shared.toggle(for: URL(fileURLWithPath: asset.path))
                return nil
            }
        }
        .onDisappear {
            if let quickLookMonitor {
                NSEvent.removeMonitor(quickLookMonitor)
            }
            DAMQuickLookPanelController.shared.close()
        }
        .sheet(isPresented: $showingCollectionSheet) {
            collectionSheet
        }
        .sheet(isPresented: $showingOffloadSheet) {
            DAMOffloadSheet(viewModel: viewModel)
        }
    }

    /// Loading overlay for the initial catalog load. Uses the same themed
    /// block-bar graphic as the Storage Map scan so the app skin stays
    /// consistent.
    private var retroLoadingOverlay: some View {
        VStack(spacing: 20) {
            Spacer()
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                DAMThemeProgressOverlay(
                    message: loadingStep,
                    fraction: nil,
                    countText: nil,
                    etaText: nil,
                    elapsedSeconds: context.date.timeIntervalSince(appLoadStartDate),
                    currentItem: nil,
                    secondaryFraction: nil,
                    secondaryCountText: nil,
                    secondaryEtaText: nil
                )
            }
            if viewModel.assets.isEmpty {
                Text("MaestroDAM is loading your catalog. This may take a moment for large libraries.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    /// Progress overlay shown while cropping/redacting selected assets before
    /// handing them to the system share sheet.
    private var sharePreparationOverlay: some View {
        VStack(spacing: 20) {
            Spacer()
            let fraction = shareProgressTotal > 0
                ? Double(shareProgressDone) / Double(shareProgressTotal)
                : 0.0
            DAMThemeProgressOverlay(
                message: "Preparing share…",
                fraction: fraction,
                countText: "\(shareProgressDone) / \(shareProgressTotal)",
                etaText: nil,
                elapsedSeconds: nil,
                currentItem: nil,
                secondaryFraction: nil,
                secondaryCountText: nil,
                secondaryEtaText: nil
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch viewModel.workspace {
        case .home: homeBody
        case .metadata: metadataBody
        case .edit: EditWorkspaceView(viewModel: viewModel)
        case .output: OutputWorkspaceView(viewModel: viewModel)
        }
    }

    // MARK: - Toolbar

    /// Selected assets, used by the Share and Crop toolbar actions.
    private var selectedAssets: [DAMAsset] {
        viewModel.assets
            .filter { viewModel.selection.contains($0.id) }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { showFolderTree.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Show/hide the Folders tree")

            Picker("View", selection: $homeViewMode) {
                ForEach(HomeViewMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Menu {
                Button { viewModel.importFolderWithPanel() } label: {
                    Label("Import Folder…", systemImage: "folder")
                }
                Button { showingOffloadSheet = true } label: {
                    Label("Offload & Import…", systemImage: "externaldrive.badge.timemachine")
                }
                Button { viewModel.importLightroomCSVWithPanel() } label: {
                    Label("Import Lightroom CSV…", systemImage: "tablecells")
                }
                Button { viewModel.importLrcatWithPanel() } label: {
                    Label("Import Lightroom Catalog (.lrcat)…", systemImage: "doc.text")
                }
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.isImporting || viewModel.isImportingLightroom
                       || viewModel.isImportingLrcat || viewModel.isOffloading)

            if viewModel.isImportingLrcat {
                Button {
                    viewModel.cancelLrcatImport()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)

                RetroScanIndicator(message: viewModel.lrcatProgress.isEmpty ? "Importing catalog…" : viewModel.lrcatProgress)
                    .scaleEffect(0.65)
                    .frame(width: 180)
            } else if let summary = viewModel.lrcatSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if viewModel.isImportingLightroom {
                Button {
                    viewModel.cancelLightroomImport()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)

                RetroScanIndicator(message: viewModel.lightroomProgress.isEmpty ? "Importing Lightroom metadata…" : viewModel.lightroomProgress)
                    .scaleEffect(0.65)
                    .frame(width: 180)
            } else if let summary = viewModel.lightroomSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if viewModel.isImporting {
                Button {
                    viewModel.cancelImport()
                } label: {
                    Label("Cancel Import", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)

                RetroScanIndicator(message: "Scanning \(viewModel.importScanned) files · \(viewModel.importWritten) cataloged")
                    .scaleEffect(0.65)
                    .frame(width: 180)
            }

            Spacer()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Picker("Sort", selection: Binding(
                        get: { viewModel.sortOrder },
                        set: { viewModel.sortOrder = $0 }
                    )) {
                        ForEach(DAMDatabase.DAMSortOrder.allCases, id: \.self) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    .frame(width: 140)

                    Picker("Rating", selection: Binding(
                        get: { viewModel.minimumRating },
                        set: { viewModel.minimumRating = $0 }
                    )) {
                        Text("All ratings").tag(0)
                        ForEach(1...5, id: \.self) { stars in
                            Text("\(stars)+ ★").tag(stars)
                        }
                    }
                    .frame(width: 110)

                    // Tag color filter
                    Menu {
                        Button("All tags") { viewModel.filterTagColor = nil }
                        Divider()
                        Button("Green") { viewModel.filterTagColor = 2 }
                        Button("Purple") { viewModel.filterTagColor = 3 }
                        Button("Blue") { viewModel.filterTagColor = 4 }
                        Button("Yellow") { viewModel.filterTagColor = 5 }
                        Button("Red") { viewModel.filterTagColor = 6 }
                        Button("Orange") { viewModel.filterTagColor = 7 }
                        Divider()
                        Button("Tagged only") { viewModel.filterTagged = true }
                        Button("Untagged only") { viewModel.filterTagged = false }
                        Button("Clear tag filter") { viewModel.filterTagged = nil }
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
                    .frame(width: 80)

                    // File type filter
                    Picker("Type", selection: Binding(
                        get: { viewModel.filterFileType },
                        set: { viewModel.filterFileType = $0 }
                    )) {
                        Text("All types").tag(nil as String?)
                        Text("Images").tag("image" as String?)
                        Text("RAW").tag("raw" as String?)
                        Text("Video").tag("movie" as String?)
                        Text("Audio").tag("audio" as String?)
                        Text("PDF").tag("pdf" as String?)
                    }
                    .frame(width: 100)

                    // Flag filter
                    Picker("Flag", selection: Binding(
                        get: { viewModel.filterFlag },
                        set: { viewModel.filterFlag = $0 }
                    )) {
                        Text("All flags").tag(nil as DAMFlag?)
                        Text("Picked").tag(DAMFlag.pick as DAMFlag?)
                        Text("Rejected").tag(DAMFlag.reject as DAMFlag?)
                    }
                    .frame(width: 90)

                    Button {
                        viewModel.togglePrivacyMode()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: viewModel.privacyModeActive
                                  ? "eye.slash.fill"
                                  : "eye.slash")
                            if viewModel.privacyScanningCount > 0 {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 12, height: 12)
                            }
                        }
                    }
                    .help(viewModel.privacyModeActive
                          ? "Privacy mode is on — redactions are visible"
                          : "Privacy mode — hide faces and sensitive content for screen sharing")
                    .buttonStyle(BorderlessButtonStyle())
                    .foregroundStyle(viewModel.privacyModeActive ? .red : .primary)

                    Divider().frame(height: 16)

                    // ROTATE: rotate all selected assets 90° counter-clockwise (matches icon).
                    Button {
                        viewModel.rotateSelectedAssets(clockwise: false)
                    } label: {
                        Image(systemName: "rotate.left")
                    }
                    .help("Rotate selected 90° counter-clockwise")
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled(viewModel.selection.isEmpty)

                    // SHARE: flatten edits/redactions then present the native
                    // macOS share sheet. Originals are only shared untouched
                    // when no visible edits exist.
                    Button {
                        Task { await prepareAndShareSelectedAssets() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("Share selected assets")
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled(selectedAssets.isEmpty || isPreparingShare)

                    // CROP: open a Quick Look-style modal crop sheet.
                    Button {
                        if let asset = viewModel.primaryAsset ?? selectedAssets.first {
                            quickCropAsset = asset
                        }
                    } label: {
                        Image(systemName: "crop")
                    }
                    .help("Quick crop")
                    .buttonStyle(BorderlessButtonStyle())
                    .disabled(viewModel.selection.count != 1)

                    TextField("Search catalog", text: Binding(
                        get: { viewModel.searchText },
                        set: { viewModel.searchText = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

                    Button {
                        withAnimation { showPreviewPanel.toggle() }
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help("Show/hide the Preview panel")
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Share preparation

    private func prepareAndShareSelectedAssets() async {
        let assets = selectedAssets
        guard !assets.isEmpty else { return }

        await MainActor.run {
            isPreparingShare = true
            shareProgressDone = 0
            shareProgressTotal = assets.count
        }
        defer {
            Task { @MainActor in
                isPreparingShare = false
                shareProgressDone = 0
                shareProgressTotal = 0
            }
        }

        do {
            let urls = try await DAMShareService.prepareShareURLs(for: assets) { done, total in
                Task { @MainActor in
                    shareProgressDone = done
                    shareProgressTotal = total
                }
            }
            await MainActor.run {
                presentSharePicker(urls: urls)
            }
        } catch {
            await MainActor.run {
                viewModel.setErrorMessage("Could not prepare assets for sharing: \(error.localizedDescription)")
            }
        }
    }

    /// Present `NSSharingServicePicker` anchored to the key window.
    private func presentSharePicker(urls: [URL]) {
        guard !urls.isEmpty,
              let window = NSApp.keyWindow,
              let contentView = window.contentView else { return }
        let picker = NSSharingServicePicker(items: urls as [Any])
        picker.show(
            relativeTo: contentView.bounds,
            of: contentView,
            preferredEdge: .minY
        )
    }

    // MARK: - Left: Folders tree

    private var folderTreePanel: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                volumesSidebarSection

                DAMSidebarDivider { delta in
                    let headerHeight: CGFloat = 28
                    let dividerHeight: CGFloat = 1
                    let minCatalogHeight: CGFloat = 60
                    let maxVolumes = max(60, geometry.size.height - dividerHeight - headerHeight * 2 - minCatalogHeight)
                    volumesSectionHeight = min(max(60, volumesSectionHeight + delta), maxVolumes)
                }

                catalogSidebarSection
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Catalog section: All Assets, Collections, and catalog folder tree.
    private var catalogSidebarSection: some View {
        DAMSidebarSection(
            title: "Catalog",
            isExpanded: $catalogSectionExpanded,
            height: nil
        ) {
            Button {
                Task { await viewModel.refreshFolderTree() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Rescan catalog folders, volumes, and collections")
        } content: {
            List(selection: catalogSidebarSelection) {
                    Label("All Assets", systemImage: "photo.on.rectangle.angled")
                        .tag("")

                    Section {
                        if viewModel.collections.isEmpty {
                            Text("No collections yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .tag("collections.empty")
                                .disabled(true)
                        } else {
                            ForEach(flattenedCollectionItems) { item in
                                CollectionRow(
                                    collection: item.collection,
                                    count: viewModel.collectionAssetCounts[item.collection.id ?? -1],
                                    depth: item.depth,
                                    viewModel: viewModel,
                                    onRename: {
                                        prepareCollectionSheet(editing: item.collection)
                                    }
                                )
                                .tag(collectionTag(for: item.collection))
                            }
                        }
                    } header: {
                        HStack {
                            Text("Collections")
                            Spacer()
                            Button {
                                prepareCollectionSheet(editing: nil)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Create new collection")
                        }
                    }

                    if !viewModel.folderTree.isEmpty {
                        Section("Folders") {
                            OutlineGroup(viewModel.folderTree, children: \.children) { node in
                                Button {
                                    handleFolderTap(node.path)
                                } label: {
                                    folderRow(for: node)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(viewModel.selectedFolder == node.path ? Color.accentColor.opacity(0.25) : Color.clear)
                                .tag(node.path)
                                .onDrag { folderDragPayload(for: node.path) }
                                .onDrop(of: [UTType.plainText.identifier], isTargeted: dropBinding(for: node.path)) { providers, _ in
                                    handleFolderDrop(providers: providers, onto: node.path)
                                }
                                .contextMenu { folderContextMenu(for: node) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
    }

    /// Volumes section: mounted drives outside the catalog.
    private var volumesSidebarSection: some View {
        DAMSidebarSection(
            title: "Volumes",
            isExpanded: $volumesSectionExpanded,
            height: CGFloat(volumesSectionHeight)
        ) {
            List(selection: volumesSidebarSelection) {
                if viewModel.volumeNodes.isEmpty {
                    Text("No volumes mounted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .tag("volumes.empty")
                        .disabled(true)
                } else {
                    ForEach(viewModel.volumeNodes) { node in
                        folderRow(for: node, icon: "internaldrive")
                            .tag(node.path)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var volumePaths: Set<String> {
        Set(viewModel.volumeNodes.map(\.path))
    }

    private var catalogSidebarSelection: Binding<String?> {
        Binding<String?>(
            get: {
                if let id = viewModel.selectedCollectionID {
                    return "collection:\(id)"
                }
                // Folders are managed by the OutlineGroup's own selection binding.
                if viewModel.selectedFolder != nil {
                    return nil
                }
                return ""
            },
            set: { tag in
                if let tag, tag.hasPrefix("collection:") {
                    let idString = String(tag.dropFirst("collection:".count))
                    viewModel.selectedCollectionID = Int64(idString)
                    viewModel.selectedFolder = nil
                    selectedFolderPaths.removeAll()
                } else {
                    viewModel.selectedCollectionID = nil
                    viewModel.selectedFolder = (tag?.isEmpty == false) ? tag : nil
                    selectedFolderPaths.removeAll()
                    if let tag, !tag.isEmpty {
                        selectedFolderPaths.insert(tag)
                    }
                }
            }
        )
    }


    private var volumesSidebarSelection: Binding<String?> {
        Binding<String?>(
            get: {
                guard let folder = viewModel.selectedFolder,
                      volumePaths.contains(folder) else { return nil }
                return folder
            },
            set: { tag in
                viewModel.selectedCollectionID = nil
                viewModel.selectedFolder = tag
            }
        )
    }

    private func collectionTag(for collection: DAMCollection) -> String {
        "collection:\(collection.id ?? -1)"
    }

    /// Collections that can be chosen as a parent for the one being edited.
    /// Prevents selecting the collection itself or any of its descendants
    /// (which would create a cycle).
    private var eligibleParentCollections: [DAMCollection] {
        guard let editing = editingCollection else { return viewModel.collections }
        let forbidden = descendantIDs(of: editing.id ?? -1).union([editing.id ?? -1])
        return viewModel.collections.filter { !forbidden.contains($0.id ?? -1) }
    }

    private func descendantIDs(of id: Int64) -> Set<Int64> {
        let byParent = Dictionary(grouping: viewModel.collections) { $0.parentId ?? -1 }
        var result = Set<Int64>()
        func visit(_ parentId: Int64) {
            for child in byParent[parentId] ?? [] {
                let childId = child.id ?? -1
                guard result.insert(childId).inserted else { continue }
                visit(childId)
            }
        }
        visit(id)
        return result
    }

    /// Flattened, depth-aware list of collections for the sidebar.
    private var flattenedCollectionItems: [CollectionListItem] {
        let byParent = Dictionary(grouping: viewModel.collections) { $0.parentId ?? -1 }
        func flatten(parentId: Int64, depth: Int) -> [CollectionListItem] {
            let children = byParent[parentId] ?? []
            let sorted = children.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return sorted.flatMap { collection in
                [CollectionListItem(collection: collection, depth: depth)]
                    + flatten(parentId: collection.id ?? -1, depth: depth + 1)
            }
        }
        return flatten(parentId: -1, depth: 0)
    }

    /// IDs to drag from the grid: the current selection if this asset is part
    /// of it, otherwise just the asset under the cursor.
    private func draggedAssetIDs(for asset: DAMAsset) -> String {
        let id = asset.id ?? -1
        let ids: [Int64]
        if viewModel.selection.contains(id) {
            ids = viewModel.selection.compactMap { $0 }
        } else {
            ids = [id]
        }
        return ids.map(String.init).joined(separator: ",")
    }

    // MARK: - Collection sidebar row with drop target

    private struct CollectionListItem: Identifiable {
        let collection: DAMCollection
        let depth: Int
        var id: Int64? { collection.id }
    }

    private struct CollectionRow: View {
        let collection: DAMCollection
        let count: Int?
        let depth: Int
        let viewModel: DAMViewModel
        let onRename: () -> Void
        @State private var isDropTargeted = false

        private var collectionIcon: String {
            collection.kind == .smart ? "gear.badge.checkmark" : "folder.badge.person.crop"
        }

        private var draggablePayload: String {
            "collection:\(collection.id ?? -1)"
        }

        var body: some View {
            HStack {
                Image(systemName: collectionIcon)
                    .foregroundStyle(.secondary)
                Text(collection.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if collection.kind == .smart {
                    Text("smart")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
            .contextMenu { collectionContextMenu() }
            .onDrag {
                NSItemProvider(object: draggablePayload as NSString)
            }
            .onDrop(of: [UTType.plainText.identifier], isTargeted: $isDropTargeted) { providers, _ in
                guard collection.kind == .manual, let provider = providers.first else { return false }
                provider.loadObject(ofClass: String.self) { object, _ in
                    guard let string = object,
                          let targetId = collection.id else { return }
                    if string.hasPrefix("collection:") {
                        let movedIdString = String(string.dropFirst("collection:".count))
                        guard let movedId = Int64(movedIdString),
                              movedId != targetId else { return }
                        Task { @MainActor in
                            await viewModel.setCollectionParent(id: movedId, parentId: targetId)
                        }
                    } else {
                        let ids = string
                            .components(separatedBy: ",")
                            .compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
                            .filter { $0 >= 0 }
                        guard !ids.isEmpty else { return }
                        Task { @MainActor in
                            await viewModel.addAssetIds(ids, to: targetId)
                        }
                    }
                }
                return true
            }
            .background(isDropTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
        }

        @ViewBuilder
        private func collectionContextMenu() -> some View {
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            let eligible = eligibleParents()
            if !eligible.isEmpty {
                Menu {
                    Button {
                        Task { await viewModel.setCollectionParent(id: collection.id ?? -1, parentId: nil) }
                    } label: {
                        Label("Top level", systemImage: "arrow.up.backward")
                    }
                    ForEach(eligible) { parent in
                        Button {
                            Task { await viewModel.setCollectionParent(id: collection.id ?? -1, parentId: parent.id) }
                        } label: {
                            Text(parent.name)
                        }
                    }
                } label: {
                    Label("Move into…", systemImage: "folder")
                }
            }

            Button(role: .destructive) {
                Task { await viewModel.deleteCollection(id: collection.id ?? -1) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }

        private func eligibleParents() -> [DAMCollection] {
            let forbidden = descendantIDs(of: collection.id ?? -1)
                .union([collection.id ?? -1])
            return viewModel.collections
                .filter { !forbidden.contains($0.id ?? -1) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        private func descendantIDs(of id: Int64) -> Set<Int64> {
            let byParent = Dictionary(grouping: viewModel.collections) { $0.parentId ?? -1 }
            var result = Set<Int64>()
            func visit(_ parentId: Int64) {
                for child in byParent[parentId] ?? [] {
                    let childId = child.id ?? -1
                    guard result.insert(childId).inserted else { continue }
                    visit(childId)
                }
            }
            visit(id)
            return result
        }
    }

    @ViewBuilder
    private func folderRow(for node: DAMFolderNode, icon: String = "folder") -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            // Colored tag dots for this folder
            if let colors = viewModel.folderTagColors[node.path] {
                HStack(spacing: 2) {
                    ForEach(colors, id: \.self) { idx in
                        Circle()
                            .fill(DAMBrowserView.finderColor(for: idx))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            Spacer()
            if node.count > 0 {
                Text("\(node.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Shared center pieces

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Catalog") { viewModel.selectedFolder = nil }
                    .buttonStyle(.link)
                if let folder = viewModel.selectedFolder {
                    let components = folder.split(separator: "/").map(String.init)
                    ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                        Text("›")
                            .foregroundStyle(.secondary)
                        let prefix = "/" + components.prefix(index + 1).joined(separator: "/")
                        Button(name) {
                            viewModel.selectedFolder = prefix
                        }
                        .buttonStyle(.link)
                        // Show colored tag dots after folder names in breadcrumb
                        if let colors = viewModel.folderTagColors[prefix] {
                            HStack(spacing: 1) {
                                ForEach(colors, id: \.self) { idx in
                                    Circle()
                                        .fill(DAMBrowserView.finderColor(for: idx))
                                        .frame(width: 5, height: 5)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if let error = viewModel.errorMessage {
            ContentUnavailableView {
                Label("Catalog Error", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if viewModel.assets.isEmpty {
            ContentUnavailableView {
                Label("No Assets Yet", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Import a folder to start building your catalog.\nRatings, tags, and AI keywording stay on this Mac.")
            } actions: {
                Button("Import Folder…") { viewModel.importFolderWithPanel() }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(viewModel.assets) { asset in
                        DAMThumbnailCell(
                            asset: asset,
                            isSelected: viewModel.selection.contains(asset.id ?? -1)
                        )
                        .onTapGesture { handleGridTap(asset) }
                        .contextMenu { gridContextMenu(for: asset) }
                        .onDrag {
                            NSItemProvider(object: draggedAssetIDs(for: asset) as NSString)
                        }
                        .task { await viewModel.loadMoreIfNeeded(currentItem: asset) }
                    }
                }
                .padding(12)
            }
        }
    }

    private func handleGridTap(_ asset: DAMAsset) {
        if NSEvent.modifierFlags.contains(.command) {
            viewModel.toggleSelection(asset.id)
        } else {
            viewModel.selectSingle(asset.id)
        }
    }

    @ViewBuilder
    private func gridContextMenu(for asset: DAMAsset) -> some View {
        let id = asset.id ?? -1
        // PURE builder — NO selection writes here. SwiftUI eagerly evaluates
        // .contextMenu closures during ordinary render passes, so a
        // `Task { selectSingle(id) }` side effect fired for every visible
        // unselected cell: each re-asserted ITSELF as the selection, which
        // re-rendered and re-asserted the next — primarySelectedID
        // ping-ponged between two ids every frame (AttributeGraph churn,
        // preview .task cancelled in its debounce → permanent spinner).
        // The menu acts on the EFFECTIVE selection instead: the
        // right-clicked asset when it isn't selected, else the selection.
        let effective: Set<DAMAsset.ID> = viewModel.selection.contains(id)
            ? viewModel.selection : [id]

        let manualCollections = viewModel.collections.filter { $0.kind == .manual }
        if !manualCollections.isEmpty {
            Menu {
                ForEach(manualCollections) { collection in
                    Button {
                        Task { await viewModel.addSelectionToCollection(collection.id ?? -1) }
                    } label: {
                        Text(collection.name)
                    }
                }
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
            }
        }

        if let selectedID = viewModel.selectedCollectionID,
           let collection = viewModel.collections.first(where: { $0.id == selectedID }),
           collection.kind == .manual {
            Button {
                Task { await viewModel.removeSelectionFromActiveCollection() }
            } label: {
                Label("Remove from Collection", systemImage: "folder.badge.minus")
            }
        }

        DAMContextMenu.items(
            viewModel: viewModel,
            assets: viewModel.assets.filter { effective.contains($0.id ?? -1) },
            ids: effective)
    }

    @ViewBuilder
    private func folderContextMenu(for node: DAMFolderNode) -> some View {
        Button {
            Task { await viewModel.generateTagsForFolder(node.path) }
        } label: {
            Label("Generate Tags for Folder", systemImage: "folder.badge.sparkles")
        }

        let eligible = eligibleFolderTargets(excluding: node.path)
        if !eligible.isEmpty {
            Menu {
                ForEach(eligible, id: \.path) { target in
                    Button {
                        Task { await viewModel.moveFolder(path: node.path, toParent: target.path) }
                    } label: {
                        Text(target.name)
                    }
                }
            } label: {
                Label("Move into…", systemImage: "folder")
            }
        }

        if let topParent = topLevelParent(for: node.path),
           topParent != (node.path as NSString).deletingLastPathComponent {
            Button {
                Task { await viewModel.moveFolder(path: node.path, toParent: topParent) }
            } label: {
                Label("Move to Top Level", systemImage: "arrow.up.backward")
            }
        }
    }

    // MARK: - Folder tree helpers

    private func handleFolderTap(_ path: String) {
        if NSEvent.modifierFlags.contains(.command) {
            selectedFolderPaths.formSymmetricDifference([path])
        } else {
            selectedFolderPaths = [path]
        }
        viewModel.selectedFolder = path
    }

    private func dropBinding(for path: String) -> Binding<Bool> {
        Binding(
            get: { dropTargetedPaths.contains(path) },
            set: { newValue in
                if newValue {
                    dropTargetedPaths.insert(path)
                } else {
                    dropTargetedPaths.remove(path)
                }
            }
        )
    }

    private func folderDragPayload(for path: String) -> NSItemProvider {
        let sourcePaths = Array(selectedFolderPaths.contains(path) ? selectedFolderPaths : [path])
        let prefix = "folders-json:"
        let json = (try? JSONEncoder().encode(sourcePaths))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return NSItemProvider(object: "\(prefix)\(json)" as NSString)
    }

    private func handleFolderDrop(providers: [NSItemProvider], onto targetPath: String) -> Bool {
        guard let provider = providers.first else { return false }
        Task { @MainActor in
            do {
                let string = try await loadString(from: provider)
                let sourcePaths: [String]
                if string.hasPrefix("folders-json:"),
                   let data = String(string.dropFirst("folders-json:".count)).data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String].self, from: data) {
                    sourcePaths = decoded
                } else if string.hasPrefix("folder:") {
                    sourcePaths = [String(string.dropFirst("folder:".count))]
                } else {
                    viewModel.setErrorMessage("Dropped item was not a catalog folder.")
                    return
                }
                for source in sourcePaths {
                    guard source != targetPath,
                          !targetPath.hasPrefix(source + "/") else { continue }
                    await viewModel.moveFolder(path: source, toParent: targetPath)
                }
            } catch {
                viewModel.setErrorMessage("Drop failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    private func loadString(from provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: String.self) { object, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let string = object {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "DAMBrowserView",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Dropped payload could not be decoded."]
                    ))
                }
            }
        }
    }

    private func eligibleFolderTargets(excluding sourcePath: String) -> [DAMFolderNode] {
        var result: [DAMFolderNode] = []
        func visit(_ nodes: [DAMFolderNode]) {
            for node in nodes {
                if node.path != sourcePath, !node.path.hasPrefix(sourcePath + "/") {
                    result.append(node)
                }
                if let children = node.children {
                    visit(children)
                }
            }
        }
        visit(viewModel.folderTree)
        return result.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func topLevelParent(for sourcePath: String) -> String? {
        let parent = (sourcePath as NSString).deletingLastPathComponent
        let grandparent = (parent as NSString).deletingLastPathComponent
        guard grandparent != parent, !grandparent.isEmpty else { return nil }
        return grandparent
    }

    @ViewBuilder
    private func predicateRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var collectionSheet: some View {
        NavigationStack {
            Form {
                Section("Collection Name") {
                    TextField("Name", text: $newCollectionName)
                }

                Section("Type") {
                    Picker("Kind", selection: $newCollectionKind) {
                        Text("Manual Album").tag(DAMCollection.Kind.manual)
                        Text("Smart Collection").tag(DAMCollection.Kind.smart)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Location") {
                    Picker("Inside", selection: $newCollectionParentID) {
                        Text("Top level").tag(nil as Int64?)
                        ForEach(eligibleParentCollections) { collection in
                            Text(collection.name).tag(collection.id as Int64?)
                        }
                    }
                }

                if newCollectionKind == .smart {
                    Section("Match Conditions") {
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("Search words", text: $predicateQuery)
                                .autocorrectionDisabled()

                            TextField("Tags (comma separated)", text: $predicateTags)
                                .autocorrectionDisabled()

                            predicateRow(label: "Minimum rating") {
                                Picker("", selection: $predicateMinRating) {
                                    Text("Any").tag(0)
                                    ForEach(1...5, id: \.self) { n in
                                        Text(String(repeating: "★", count: n)).tag(n)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            TextField("File type", text: $predicateFileType, prompt: Text("image, video, pdf…"))
                                .autocorrectionDisabled()

                            predicateRow(label: "Flag") {
                                Picker("", selection: $predicateFlagRaw) {
                                    Text("Any").tag("")
                                    ForEach(DAMFlag.allCases.map(\.rawValue), id: \.self) { raw in
                                        Text(DAMFlag(rawValue: raw)?.displayName ?? raw).tag(raw)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            predicateRow(label: "Finder color") {
                                Picker("", selection: $predicateTagColor) {
                                    Text("Any").tag(nil as Int?)
                                    Text("Gray").tag(1)
                                    Text("Red").tag(2)
                                    Text("Orange").tag(3)
                                    Text("Yellow").tag(4)
                                    Text("Green").tag(5)
                                    Text("Blue").tag(6)
                                    Text("Purple").tag(7)
                                }
                                .pickerStyle(.segmented)
                            }

                            Toggle("Has AI keywords", isOn: $predicateHasAIKeywords)
                            Toggle("Has Finder/xattr keywords", isOn: $predicateHasXattrKeywords)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editingCollection == nil ? "New Collection" : "Edit Collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingCollectionSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let predicateJSON = buildCollectionPredicateJSON()
                            await viewModel.saveCollection(
                                id: editingCollection?.id,
                                name: newCollectionName,
                                kind: newCollectionKind,
                                predicateJSON: predicateJSON,
                                parentId: newCollectionParentID
                            )
                            showingCollectionSheet = false
                            resetCollectionSheet()
                        }
                    }
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(minWidth: 480, minHeight: newCollectionKind == .smart ? 640 : 240)
        }
    }

    private func prepareCollectionSheet(editing collection: DAMCollection?) {
        editingCollection = collection
        newCollectionName = collection?.name ?? ""
        newCollectionKind = collection?.kind ?? .manual
        newCollectionParentID = collection?.parentId
        predicateQuery = ""
        predicateTags = ""
        predicateMinRating = 0
        predicateFileType = ""
        predicateFlagRaw = ""
        predicateTagColor = nil
        predicateHasAIKeywords = false
        predicateHasXattrKeywords = false
        if let collection, collection.kind == .smart,
           let data = collection.predicateJSON?.data(using: .utf8),
           let predicate = try? JSONDecoder().decode(DAMSmartPredicate.self, from: data) {
            predicateQuery = predicate.query ?? ""
            predicateTags = predicate.tags?.joined(separator: ", ") ?? ""
            predicateMinRating = predicate.minRating ?? 0
            predicateFileType = predicate.fileType ?? ""
            predicateFlagRaw = predicate.flag?.rawValue ?? ""
            predicateTagColor = predicate.tagColor
            predicateHasAIKeywords = predicate.hasAIKeywords ?? false
            predicateHasXattrKeywords = predicate.hasXattrKeywords ?? false
        }
        showingCollectionSheet = true
    }

    private func resetCollectionSheet() {
        newCollectionName = ""
        editingCollection = nil
        newCollectionKind = .manual
        newCollectionParentID = nil
        predicateQuery = ""
        predicateTags = ""
        predicateMinRating = 0
        predicateFileType = ""
        predicateFlagRaw = ""
        predicateTagColor = nil
        predicateHasAIKeywords = false
        predicateHasXattrKeywords = false
    }

    private func buildCollectionPredicateJSON() -> String? {
        guard newCollectionKind == .smart else { return nil }
        let tags = predicateTags
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var predicate = DAMSmartPredicate()
        if !predicateQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            predicate.query = predicateQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !tags.isEmpty { predicate.tags = tags }
        if predicateMinRating > 0 { predicate.minRating = predicateMinRating }
        if !predicateFileType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            predicate.fileType = predicateFileType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let trimmedFlag = predicateFlagRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFlag.isEmpty, let flag = DAMFlag(rawValue: trimmedFlag) {
            predicate.flag = flag
        }
        if let predicateTagColor { predicate.tagColor = predicateTagColor }
        if predicateHasAIKeywords { predicate.hasAIKeywords = true }
        if predicateHasXattrKeywords { predicate.hasXattrKeywords = true }
        guard let data = try? JSONEncoder().encode(predicate) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var statusBar: some View {
        HStack {
            Text("\(viewModel.totalAssetCount.formatted()) items")
            if !viewModel.selection.isEmpty {
                Text("· \(viewModel.selection.count) selected")
            }
            Spacer()
            DAMResourceStatusView()
            if let folder = viewModel.selectedFolder {
                Text(folder)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Storage health banner

    private var storageHealthBanner: some View {
        Group {
            if !healthWarnings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("\(healthWarnings.count) drive\(healthWarnings.count == 1 ? "" : "s") need attention: \(healthWarnings.map(\.name).joined(separator: ", "))")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.15))
            }
        }
        .task { await loadHealthWarnings() }
    }

    private func loadHealthWarnings() async {
        healthWarnings = (try? await DAMDatabase.shared.dbQueue.read { db in
            try DAMVolume
                .filter(DAMVolume.Columns.healthWarnReplace == true && DAMVolume.Columns.isOnline == true)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Home: tree | grid | preview

    private var homeBody: some View {
        HStack(spacing: 0) {
            if showFolderTree {
                folderTreePanel
                    .frame(width: treeWidth)
                PanelResizeHandle(width: $treeWidth, minWidth: 170, maxWidth: 400)
            }
            VStack(spacing: 0) {
                switch homeViewMode {
                case .browser:
                    storageHealthBanner
                    breadcrumbBar
                    Divider()
                    gridContent
                    Divider()
                    statusBar
                case .statistics:
                    DAMStatisticsView(viewModel: viewModel)
                case .storageMap:
                    storageHealthBanner
                    DAMStorageMapView(viewModel: viewModel)
                case .duplicates:
                    DAMDuplicateFinderView(viewModel: viewModel)
                }
            }
            if homeViewMode == .browser, showPreviewPanel {
                PanelResizeHandle(width: $previewWidth, minWidth: 240, maxWidth: 640, invert: true)
                previewPanel
                    .frame(width: previewWidth)
            }
        }
    }

    // MARK: - Metadata: (tree + metadata panel) | list

    /// The Metadata workspace has two viewing options (persisted): the plain
    /// full-page list, and Preview + List — a large preview of the selected
    /// image above the rows so the user can see detail while scanning
    /// metadata.
    private var metadataBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showFolderTree {
                    folderTreePanel
                        .frame(width: treeWidth)
                    PanelResizeHandle(width: $treeWidth, minWidth: 170, maxWidth: 400)
                }
                VStack(spacing: 0) {
                    metadataHeader
                    Divider()
                    if metadataViewMode == .preview {
                        MetadataPreviewPane(asset: viewModel.primaryAsset)
                            .frame(minHeight: 240, idealHeight: 420, maxHeight: 560)
                        Divider()
                    }
                    ListWorkspaceView(viewModel: viewModel)
                    Divider()
                    statusBar
                }
                PanelResizeHandle(width: $metaSideWidth, minWidth: 260, maxWidth: 480, invert: true)
                MetadataPanelView(viewModel: viewModel)
                    .frame(width: metaSideWidth)
            }
            Divider()
            FilmstripBar(viewModel: viewModel, assets: viewModel.assets)
                .frame(height: 128)
        }
    }

    /// Breadcrumb trail + the Metadata view-mode picker (trailing).
    private var metadataHeader: some View {
        HStack(spacing: 0) {
            breadcrumbBar
            Spacer()
            Picker("Metadata view", selection: $metadataViewMode) {
                Label("List", systemImage: "list.bullet").tag(MetadataViewMode.list)
                Label("Preview", systemImage: "photo").tag(MetadataViewMode.preview)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 150)
            .padding(.trailing, 10)
            .help("List only, or a large preview of the selection above the list")
        }
    }

    // MARK: - Right: Preview + File Properties

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let asset = viewModel.primaryAsset {
                DAMPreviewImage(asset: asset, contentWidth: previewWidth - 24)

                HStack {
                    Text(asset.filename)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                if viewModel.selection.count > 1 {
                    Text("\(viewModel.selection.count) items selected — rating applies to all")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                DAMRatingStars(rating: asset.rating) { stars in
                    Task { await viewModel.setRating(stars, for: viewModel.selection) }
                }

                Button {
                    DAMContextMenu.reveal(
                        viewModel.assets.filter { viewModel.selection.contains($0.id ?? -1) })
                } label: {
                    Label(viewModel.selection.count > 1 ? "Show in Finder" : "Show in Finder",
                          systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .font(.caption)

                Divider()

                propertiesScroll(asset)
            } else {
                Spacer()
                HStack {
                    Spacer()
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "photo",
                        description: Text("Select an asset to preview it and edit its rating.")
                    )
                    Spacer()
                }
                Spacer()
            }
        }
        .padding(12)
    }

    private func propertiesScroll(_ asset: DAMAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                fileProperties(asset)
                keywordBlock(asset)
            }
        }
    }

    @ViewBuilder
    private func fileProperties(_ asset: DAMAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File Properties")
                .font(.subheadline.weight(.semibold))

            DAMMetaRow("Type", UTType(asset.uti ?? "")?.localizedDescription
                        ?? (asset.path as NSString).pathExtension.uppercased())
            DAMMetaRow("Size", asset.formattedSize)
            if !asset.formattedDimensions.isEmpty {
                DAMMetaRow("Dimensions", asset.formattedDimensions)
            }
            if let modified = asset.fileModDate {
                DAMMetaRow("File Modified", modified.formatted(date: .abbreviated, time: .shortened))
            }
            if let captured = asset.captureDate {
                DAMMetaRow("Captured", captured.formatted(date: .abbreviated, time: .shortened))
            }
            if let camera = [asset.cameraMake, asset.cameraModel]
                .compactMap({ $0 }).joined(separator: " ").nilIfEmpty {
                DAMMetaRow("Camera", camera)
            }
            if let lens = asset.lensModel { DAMMetaRow("Lens", lens) }
            if let iso = asset.iso { DAMMetaRow("ISO", "\(iso)") }
            if let aperture = asset.aperture {
                DAMMetaRow("Aperture", "ƒ/\(String(format: "%.1f", aperture))")
            }
            if let shutter = asset.shutterSpeed { DAMMetaRow("Shutter", shutter) }
            if let focal = asset.focalLength {
                DAMMetaRow("Focal Length", "\(String(format: "%.0f", focal)) mm")
            }
            if let lat = asset.gpsLat, let lon = asset.gpsLon {
                DAMMetaRow("GPS", String(format: "%.5f, %.5f", lat, lon))
            }
        }
    }

    @ViewBuilder
    private func keywordBlock(_ asset: DAMAsset) -> some View {
        if let keywords = asset.userKeywords, !keywords.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keywords")
                    .font(.subheadline.weight(.semibold))
                Text(keywords)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        if let xattr = asset.xattrKeywords, !xattr.isEmpty {
            DAMTagPillsView(tags: xattr, colorsJSON: asset.tagColors)
        }
        if let ai = asset.aiKeywords, !ai.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Keywords")
                    .font(.subheadline.weight(.semibold))
                Text(ai)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        if let caption = asset.aiCaption, !caption.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Caption")
                    .font(.subheadline.weight(.semibold))
                Text(caption)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Rating Stars

/// Clickable 1–5 star editor (click the current rating again to clear to 0).
/// Used in the Preview panel; writes go through DAMViewModel.setRating so
/// every change lands in the damAudit trail.
private struct DAMRatingStars: View {
    let rating: Int
    let onSet: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onSet(star == rating ? 0 : star)
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .foregroundStyle(star <= rating ? .yellow : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Preview Image

/// Large preview for the right panel. Height follows the panel width via the
/// asset's aspect ratio, so resizing the panel scales the image.
private struct DAMPreviewImage: View {
    let asset: DAMAsset
    var contentWidth: CGFloat = 276

    @State private var image: NSImage?
    @State private var loadFailed = false

    private var displayHeight: CGFloat {
        guard let width = asset.width, let height = asset.height, width > 0, height > 0 else {
            return 220
        }
        let aspect = CGFloat(height) / CGFloat(width)
        return min(720, max(140, contentWidth * aspect))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if loadFailed {
                Image(systemName: "doc")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(height: displayHeight)
        .task(id: asset.id) {
            await loadImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .damEditsDidChange)) { notification in
            guard let changedAssetId = notification.userInfo?["assetId"] as? Int64,
                  changedAssetId == asset.id else { return }
            Task { await loadImage() }
        }
    }

    private func loadImage() async {
        await MainActor.run {
            image = nil
            loadFailed = false
        }
        // Debounce: restart-safe under rapid selection churn.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        do {
            let loaded = try await ThumbnailService.shared.redactedThumbnail(for: asset, pixelSize: 1024)
            await MainActor.run {
                image = loaded
                loadFailed = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                loadFailed = true
            }
        }
    }
}

// MARK: - Metadata Preview Pane

/// Large aspect-fit preview for the Metadata workspace's Preview + List
/// mode. Unlike DAMPreviewImage (which derives height from the side panel's
/// width), this lives above the full-width list, so the HEIGHT is bounded
/// by the caller and the image fits inside it. Debounced, cancellation-
/// aware, decoded at 1600px for visible detail.
private struct MetadataPreviewPane: View {
    let asset: DAMAsset?

    @State private var image: NSImage?
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let asset {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else if loadFailed {
                    ContentUnavailableView(
                        "No Preview",
                        systemImage: "doc",
                        description: Text(asset.filename)
                    )
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "photo",
                    description: Text("Select an asset to preview it.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset?.id ?? -1) {
            await loadImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .damEditsDidChange)) { notification in
            guard let changedAssetId = notification.userInfo?["assetId"] as? Int64,
                  changedAssetId == asset?.id else { return }
            Task { await loadImage() }
        }
    }

    private func loadImage() async {
        guard let asset else {
            await MainActor.run {
                image = nil
                loadFailed = false
            }
            return
        }
        await MainActor.run {
            image = nil
            loadFailed = false
        }
        // Debounce: rapid selection churn restarts this task — don't pay
        // for a large decode until the selection settles for a beat.
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        do {
            let loaded = try await ThumbnailService.shared.redactedThumbnail(for: asset, pixelSize: 1600)
            await MainActor.run {
                image = loaded
                loadFailed = false
            }
        } catch {
            // Cancellation is not a failure — don't flash the doc icon.
            guard !Task.isCancelled else { return }
            await MainActor.run {
                loadFailed = true
            }
        }
    }
}

// MARK: - Thumbnail Cell

/// One grid cell: QuickLook/LibRaw thumbnail + filename + rating. The
/// thumbnail loads asynchronously via `ThumbnailService` (memory + disk
/// cached).
private struct DAMThumbnailCell: View {

    let asset: DAMAsset
    let isSelected: Bool

    @State private var image: NSImage?
    @State private var loadFailed = false

    /// All distinct non-gray Finder tag colors for this asset, in the
    /// order they appear in the tagColors map. Used to draw the thumbnail
    /// border: solid for one color, rainbow gradient for multiple.
    private var tagBorderColors: [Color] {
        guard let json = asset.tagColors,
              let data = json.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        else { return [] }
        // Collect non-gray colors (skip 0=none, 1=gray), deduplicated
        var seen = Set<Int>()
        var colors: [Color] = []
        for (_, idx) in map where idx > 1 {
            if seen.insert(idx).inserted {
                colors.append(DAMBrowserView.finderColor(for: idx))
            }
        }
        return colors
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .opacity(asset.isAvailable ? 1.0 : 0.65)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .opacity(asset.isAvailable ? 1.0 : 0.65)
                } else if loadFailed {
                    Image(systemName: asset.isAvailable ? "doc" : "externaldrive.fill.badge.xmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }

                if !asset.isAvailable {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "externaldrive.badge.xmark")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                                .padding(4)
                        }
                    }
                }
            }
            .frame(height: 120)
            .overlay(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    } else if tagBorderColors.count > 1 {
                        // Rainbow border: angular gradient cycling through
                        // all tag colors, stacked for a multi-color edge.
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                AngularGradient(
                                    colors: tagBorderColors + [tagBorderColors[0]],
                                    center: .center
                                ),
                                lineWidth: 2.5
                            )
                    } else if let single = tagBorderColors.first {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(single, lineWidth: 2)
                    }
                }
            )

            Text(asset.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 2) {
                if asset.rating > 0 {
                    Text(String(repeating: "★", count: asset.rating))
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                Spacer()
                Text(asset.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .task(id: asset.id) {
            await loadImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: .damEditsDidChange)) { notification in
            guard let changedAssetId = notification.userInfo?["assetId"] as? Int64,
                  changedAssetId == asset.id else { return }
            Task { await loadImage() }
        }
    }

    private func loadImage() async {
        do {
            let loaded = try await ThumbnailService.shared.redactedThumbnail(for: asset, pixelSize: 160)
            await MainActor.run {
                image = loaded
                loadFailed = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                loadFailed = true
            }
        }
    }
}

// MARK: - Helpers

private extension String {
    /// nil when the string is empty — handy for optional-joined display values.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension DAMBrowserView {
    /// Maps Finder color index to SwiftUI Color.
    /// 0=none(gray), 1=gray, 2=green, 3=purple, 4=blue, 5=yellow, 6=red, 7=orange
    static func finderColor(for index: Int) -> Color {
        switch index {
        case 1: return .gray
        case 2: return .green
        case 3: return .purple
        case 4: return .blue
        case 5: return .yellow
        case 6: return .red
        case 7: return .orange
        default: return .gray.opacity(0.4)
        }
    }
}

/// Displays Finder tags as colored pills, matching macOS Finder's style.
private struct DAMTagPillsView: View {
    let tags: String
    let colorsJSON: String?

    private var tagNames: [String] {
        tags.components(separatedBy: ", ")
    }

    private var colorMap: [String: Int] {
        guard let json = colorsJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Int]
        else { return [:] }
        return dict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Finder Tags")
                .font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 4) {
                ForEach(tagNames, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(DAMBrowserView.finderColor(for: colorMap[tag] ?? 0).opacity(0.85))
                        )
                        .foregroundStyle((colorMap[tag] ?? 0) == 0 ? Color.primary : Color.white)
                }
            }
        }
    }
}
