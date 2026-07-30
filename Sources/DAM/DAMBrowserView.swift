import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - MaestroDAM Browser View
//
// Workspace tabs under the toolbar:
//   Home      — Folders tree | thumbnail grid | Preview + File Properties
//   Filmstrip — Folders tree | big preview over filmstrip
//   Metadata  — Folders+Metadata column | sortable list
//   Libraries — Folders tree | preview-over-grid | properties panel
//   Output / Edit — see DAMOutputWorkflow.swift
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

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            WorkspaceTabBar(viewModel: viewModel)
            Divider()
            workspaceContent
        }
        .task {
            await viewModel.reload()
            await viewModel.refreshFolderTree()
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch viewModel.workspace {
        case .home: homeBody
        case .filmstrip: filmstripBody
        case .metadata: metadataBody
        case .libraries: librariesBody
        case .output: OutputWorkspaceView(viewModel: viewModel)
        case .edit: EditWorkspaceView(viewModel: viewModel)
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

            Button {
                viewModel.importFolderWithPanel()
            } label: {
                Label("Import Folder…", systemImage: "square.and.arrow.down")
            }
            .disabled(viewModel.isImporting)

            if viewModel.isImporting {
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
                        Button(name) {
                            let prefix = "/" + components.prefix(index + 1).joined(separator: "/")
                            viewModel.selectedFolder = prefix
                        }
                        .buttonStyle(.link)
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

    // MARK: - Filmstrip: tree | (big preview / filmstrip)

    private var filmstripBody: some View {
        HStack(spacing: 0) {
            if showFolderTree {
                folderTreePanel
                    .frame(width: treeWidth)
                PanelResizeHandle(width: $treeWidth, minWidth: 170, maxWidth: 400)
            }
            VStack(spacing: 0) {
                breadcrumbBar
                Divider()
                DAMBigPreview(asset: viewModel.primaryAsset)
                    .frame(minHeight: 260)
                Divider()
                FilmstripBar(viewModel: viewModel, assets: viewModel.assets)
                    .frame(height: 150)
                Divider()
                statusBar
            }
        }
    }

    // MARK: - Metadata: (tree + metadata panel) | list

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
                breadcrumbBar
                Divider()
                ListWorkspaceView(viewModel: viewModel)
                Divider()
                statusBar
            }
        }
    }

    // MARK: - Libraries: tree | (preview over grid) | properties

    private var librariesBody: some View {
        HStack(spacing: 0) {
            if showFolderTree {
                folderTreePanel
                    .frame(width: treeWidth)
                PanelResizeHandle(width: $treeWidth, minWidth: 170, maxWidth: 400)
            }
            VStack(spacing: 0) {
                breadcrumbBar
                Divider()
                // Plain VStack equal-split — NOT VSplitView: macOS VSplitView
                // + ScrollView + infinitely-flexible preview inside a
                // floating panel enters a layout feedback loop
                // (AttributeGraph cycle → runaway layout → app killed).
                DAMBigPreview(asset: viewModel.primaryAsset)
                    .frame(maxHeight: .infinity)
                Divider()
                gridContent
                    .frame(maxHeight: .infinity)
                Divider()
                statusBar
            }
            if showPreviewPanel {
                PanelResizeHandle(width: $previewWidth, minWidth: 240, maxWidth: 640, invert: true)
                propertiesPanel
                    .frame(width: previewWidth)
            }
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

    /// Properties-only right panel (Libraries — the big preview sits center).
    private var propertiesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let asset = viewModel.primaryAsset {
                Text(asset.filename)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)

                DAMRatingStars(rating: asset.rating) { stars in
                    Task { await viewModel.setRating(stars, for: viewModel.selection) }
                }

                Divider()

                propertiesScroll(asset)
            } else {
                Spacer()
                HStack {
                    Spacer()
                    ContentUnavailableView(
                        "No Selection",
                        systemImage: "photo",
                        description: Text("Select an asset to inspect it.")
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
            VStack(alignment: .leading, spacing: 4) {
                Text("Finder Tags")
                    .font(.subheadline.weight(.semibold))
                Text(xattr)
                    .font(.caption)
                    .textSelection(.enabled)
            }
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

// MARK: - Thumbnail Cell

/// One grid cell: QuickLook/LibRaw thumbnail + filename + rating. The
/// thumbnail loads asynchronously via `ThumbnailService` (memory + disk
/// cached).
private struct DAMThumbnailCell: View {

    let asset: DAMAsset
    let isSelected: Bool

    @State private var image: NSImage?
    @State private var loadFailed = false

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
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
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
