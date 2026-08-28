import AppKit
import SwiftUI
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
// Every page shows the persistent FilmstripBar browser strip at the bottom
// (mounted below, outside the workspace switch, so it keeps its identity
// across tab switches).
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
    /// Metadata workspace viewing option: full-page list, or a large preview
    /// of the selected image above the list (persisted across launches).
    @AppStorage("dam.metadataViewMode") private var metadataViewMode: MetadataViewMode = .list

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
            // Lightroom/Capture One-style persistent browser strip: the same
            // loaded page with the same selection highlighted on every tool
            // page. Mounted OUTSIDE the workspace switch so it keeps its
            // identity across tab switches — no thumbnail reloads, scroll
            // position preserved, and the auto-scroll-to-selection task
            // re-centres the selected thumb whenever the selection moves.
            Divider()
            FilmstripBar(viewModel: viewModel, assets: viewModel.assets)
                .frame(height: 128)
        }
        .task {
            await viewModel.reload()
            await viewModel.refreshFolderTree()
            viewModel.startBackgroundEnrichment()
        }
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation { showFolderTree.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Show/hide the Folders tree")

            Menu {
                Button { viewModel.importFolderWithPanel() } label: {
                    Label("Import Folder…", systemImage: "folder")
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
                       || viewModel.isImportingLrcat)

            if viewModel.isImportingLrcat {
                Button {
                    viewModel.cancelLrcatImport()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)

                Text(viewModel.lrcatProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

                Text(viewModel.lightroomProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

                Text("Scanning \(viewModel.importScanned) files · \(viewModel.importWritten) cataloged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

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

            TextField("Search catalog", text: Binding(
                get: { viewModel.searchText },
                set: { viewModel.searchText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)

            Button {
                withAnimation { showPreviewPanel.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Show/hide the Preview panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Left: Folders tree

    private var folderTreePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Folders")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await viewModel.refreshFolderTree() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rescan catalog folders")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            List(selection: Binding<String?>(
                get: { viewModel.selectedFolder ?? "" },
                set: { viewModel.selectedFolder = ($0?.isEmpty == false) ? $0 : nil }
            )) {
                Label("All Assets", systemImage: "photo.on.rectangle.angled")
                    .tag("")
                OutlineGroup(viewModel.folderTree, children: \.children) { node in
                    HStack {
                        Image(systemName: "folder")
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
                        Text("\(node.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(node.path)
                }
            }
            .listStyle(.sidebar)
        }
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
        DAMContextMenu.items(
            viewModel: viewModel,
            assets: viewModel.assets.filter { effective.contains($0.id ?? -1) },
            ids: effective)
    }

    private var statusBar: some View {
        HStack {
            Text("\(viewModel.totalAssetCount.formatted()) items")
            if !viewModel.selection.isEmpty {
                Text("· \(viewModel.selection.count) selected")
            }
            Spacer()
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

    // MARK: - Home: tree | grid | preview

    private var homeBody: some View {
        HStack(spacing: 0) {
            if showFolderTree {
                folderTreePanel
                    .frame(width: treeWidth)
                PanelResizeHandle(width: $treeWidth, minWidth: 170, maxWidth: 400)
            }
            VStack(spacing: 0) {
                breadcrumbBar
                Divider()
                gridContent
                Divider()
                statusBar
            }
            if showPreviewPanel {
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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if showFolderTree {
                    folderTreePanel
                        .frame(height: 280)
                    Divider()
                }
                MetadataPanelView(viewModel: viewModel)
            }
            .frame(width: metaSideWidth)
            PanelResizeHandle(width: $metaSideWidth, minWidth: 260, maxWidth: 480)
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
            image = nil
            loadFailed = false
            // Debounce: restart-safe under rapid selection churn.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                image = try await ThumbnailService.shared.thumbnail(
                    for: URL(fileURLWithPath: asset.path), pixelSize: 1024)
            } catch {
                guard !Task.isCancelled else { return }
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
            guard let asset else {
                image = nil
                loadFailed = false
                return
            }
            image = nil
            loadFailed = false
            // Debounce: rapid selection churn restarts this task — don't pay
            // for a large decode until the selection settles for a beat.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                image = try await ThumbnailService.shared.thumbnail(
                    for: URL(fileURLWithPath: asset.path), pixelSize: 1600)
            } catch {
                // Cancellation is not a failure — don't flash the doc icon.
                guard !Task.isCancelled else { return }
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
                        .controlSize(.small)
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
        .task {
            do {
                image = try await ThumbnailService.shared.thumbnail(
                    for: URL(fileURLWithPath: asset.path))
            } catch {
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
