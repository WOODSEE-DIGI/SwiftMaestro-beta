import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - MaestroDAM Workspace Layouts
//
// Bridge-style workspace tabs and the shared building blocks behind
// them: Filmstrip (big preview + thumbnail strip), Metadata (sortable list
// + metadata/keywords panel), Libraries (preview-over-grid + properties),
// plus the resizable-panel drag handle and the unified context menu used by
// every workspace. Output/Edit live in `DAMOutputWorkflow.swift`.

// MARK: - Workspace enum

/// Bridge-style workspace layouts. Persisted via `DAMViewModel.workspace`.
/// Tab names are deliberately generic (Home/Edit, not Essentials/Workflow)
/// to avoid any Adobe look-and-feel entanglement.
enum DAMWorkspace: String, CaseIterable, Identifiable, Sendable {
    case home, filmstrip, metadata, libraries, output, edit

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .home: return "house"
        case .filmstrip: return "film"
        case .metadata: return "list.bullet.rectangle"
        case .libraries: return "books.vertical"
        case .output: return "square.and.arrow.up"
        case .edit: return "square.and.pencil"
        }
    }

    var help: String {
        switch self {
        case .home: return "Folders, thumbnail grid, and Preview + File Properties"
        case .filmstrip: return "Large preview with a scrolling filmstrip of thumbnails"
        case .metadata: return "Sortable list view with full metadata and keyword editing"
        case .libraries: return "Preview over grid with a properties panel"
        case .output: return "Export the selection (JPEG render or copy originals)"
        case .edit: return "Batch operations on the selection (rating, keywords)"
        }
    }
}

// MARK: - Workspace tab bar

/// The Bridge-style workspace switcher — a slim centered tab row under the
/// main toolbar.
struct WorkspaceTabBar: View {
    var viewModel: DAMViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DAMWorkspace.allCases) { workspace in
                let isActive = viewModel.workspace == workspace
                Button {
                    viewModel.workspace = workspace
                } label: {
                    Label(workspace.title, systemImage: workspace.icon)
                        .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isActive ? Color.accentColor.opacity(0.25) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(isActive ? .primary : .secondary)
                .help(workspace.help)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Panel resize handle

/// Draggable divider that adjusts a panel width. Use `invert: true` when the
/// handle sits on the panel's LEADING edge (right-side panels), so dragging
/// left widens the panel.
struct PanelResizeHandle: View {
    @Binding var width: Double
    var minWidth: Double = 220
    var maxWidth: Double = 640
    var invert: Bool = false

    @State private var dragBase: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 9)
            .overlay(Divider(), alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragBase == nil { dragBase = width }
                        let base = dragBase ?? width
                        let delta = invert ? -value.translation.width : value.translation.width
                        width = Swift.min(maxWidth, Swift.max(minWidth, base + delta))
                    }
                    .onEnded { _ in dragBase = nil }
            )
    }
}

// MARK: - Big preview (Filmstrip / Libraries)

/// Large aspect-fit preview of the primary selection, rendered through the
/// same ThumbnailService pipeline (QL/LibRaw) at 1600pt.
struct DAMBigPreview: View {
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
            // Debounce: rapid selection churn (arrow-key browsing, layout
            // re-renders) restarts this task — don't pay for a large decode
            // until the selection settles for a beat.
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

// MARK: - Filmstrip bar

/// Horizontal scrolling thumbnail strip synced to the selection. Used by the
/// Filmstrip workspace (whole loaded page) and by Output/Edit (selection
/// only). ⌘-click toggles multi-selection, like the grid.
struct FilmstripBar: View {
    var viewModel: DAMViewModel
    /// Assets to show — caller decides (loaded page vs selection-only).
    let assets: [DAMAsset]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(assets) { asset in
                        FilmstripCell(
                            asset: asset,
                            isSelected: viewModel.selection.contains(asset.id ?? -1)
                        )
                        .id(asset.id ?? -1)
                        .onTapGesture { handleTap(asset) }
                        .contextMenu { contextMenu(for: asset) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            // Observes the STABLE primary selection (never Set.first — see
            // DAMViewModel.primarySelectedID). .task(id:) coalesces ⌘-click
            // bursts into one scroll instead of re-entering the animation
            // mid-flight.
            .task(id: viewModel.primarySelectedID) {
                if let primary = viewModel.primarySelectedID {
                    withAnimation { proxy.scrollTo(primary, anchor: .center) }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func handleTap(_ asset: DAMAsset) {
        if NSEvent.modifierFlags.contains(.command) {
            viewModel.toggleSelection(asset.id)
        } else {
            viewModel.selectSingle(asset.id)
        }
    }

    @ViewBuilder
    private func contextMenu(for asset: DAMAsset) -> some View {
        let id = asset.id ?? -1
        // PURE builder — NO selection writes here (see gridContextMenu in
        // DAMBrowserView): eagerly-evaluated menu builders with a
        // selectSingle side effect ping-ponged primarySelectedID between
        // cells every frame. The menu acts on the EFFECTIVE selection:
        // the right-clicked asset when it isn't selected, else the
        // selection itself.
        let effective: Set<DAMAsset.ID> = viewModel.selection.contains(id)
            ? viewModel.selection : [id]
        DAMContextMenu.items(
            viewModel: viewModel,
            assets: viewModel.assets.filter { effective.contains($0.id ?? -1) },
            ids: effective)
    }
}

/// One filmstrip cell — fixed-square thumbnail with a selection ring.
private struct FilmstripCell: View {
    let asset: DAMAsset
    let isSelected: Bool

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 116, height: 116)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        )
        .help(asset.filename)
        .task {
            image = try? await ThumbnailService.shared.thumbnail(
                for: URL(fileURLWithPath: asset.path))
        }
    }
}

// MARK: - Metadata workspace: sortable list

/// Bridge's Content panel in list mode: sortable columns, multi-select,
/// context menu. Drives the same selection as the grid.
struct ListWorkspaceView: View {
    var viewModel: DAMViewModel

    @State private var sortOrder: [KeyPathComparator<DAMAsset>] = []

    private var sortedAssets: [DAMAsset] {
        sortOrder.isEmpty ? viewModel.assets : viewModel.assets.sorted(using: sortOrder)
    }

    private var selectionBinding: Binding<Set<DAMAsset.ID>> {
        Binding(
            get: { viewModel.selection },
            set: { viewModel.setSelection($0) }
        )
    }

    var body: some View {
        Table(sortedAssets, selection: selectionBinding, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.filename) { asset in
                Text(asset.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 140, ideal: 240)

            TableColumn("Date", value: \.sortDate) { asset in
                Text((asset.captureDate ?? asset.fileModDate)?
                    .formatted(date: .abbreviated, time: .shortened) ?? "—")
            }
            .width(150)

            TableColumn("Size", value: \.sortSize) { asset in
                Text(asset.formattedSize.isEmpty ? "—" : asset.formattedSize)
            }
            .width(80)

            TableColumn("Type", value: \.sortType) { asset in
                Text(UTType(asset.uti ?? "")?.localizedDescription
                     ?? (asset.path as NSString).pathExtension.uppercased())
                    .lineLimit(1)
            }
            .width(110)

            TableColumn("Rating", value: \.rating) { asset in
                Text(asset.rating == 0 ? "—" : String(repeating: "★", count: asset.rating))
                    .foregroundStyle(.yellow)
            }
            .width(70)

            TableColumn("Keywords") { asset in
                Text(asset.userKeywords ?? asset.xattrKeywords ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            TableColumn("Folder") { asset in
                Text(asset.folder ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .contextMenu(forSelectionType: DAMAsset.ID.self) { ids in
            DAMContextMenu.items(
                viewModel: viewModel,
                assets: viewModel.assets.filter { ids.contains($0.id ?? -1) },
                ids: ids)
        }
    }
}

// MARK: - Metadata panel (Metadata workspace left column / shared rows)

/// Full metadata + user-keyword editing for the primary selection.
/// Keyword writes go through `DAMViewModel.applyUserKeywords` (audited).
struct MetadataPanelView: View {
    var viewModel: DAMViewModel

    @State private var keywordDraft = ""
    @State private var keywordMode: DAMViewModel.KeywordApplyMode = .add

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Metadata")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                if let asset = viewModel.primaryAsset {
                    VStack(alignment: .leading, spacing: 14) {
                        fileProperties(asset)
                        keywordEditor(asset)
                        additionalText(asset)
                        iptcPlaceholder
                    }
                    .padding(12)
                } else {
                    Text("Select an asset to inspect its metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
        }
        // .task(id:) coalesces rapid same-frame selection changes (grid/list
        // clicking) — unlike .onChange, which warns "tried to update multiple
        // times per frame" when the selection churns within one render pass.
        .task(id: viewModel.primaryAsset?.id ?? -1) {
            keywordDraft = viewModel.primaryAsset?.userKeywords ?? ""
        }
    }

    @ViewBuilder
    private func fileProperties(_ asset: DAMAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File Properties")
                .font(.subheadline.weight(.semibold))
            DAMMetaRow("Filename", asset.filename)
            DAMMetaRow("Type", UTType(asset.uti ?? "")?.localizedDescription
                       ?? (asset.path as NSString).pathExtension.uppercased())
            DAMMetaRow("Size", asset.formattedSize.isEmpty ? "—" : asset.formattedSize)
            if !asset.formattedDimensions.isEmpty {
                DAMMetaRow("Dimensions", asset.formattedDimensions)
            }
            if let modified = asset.fileModDate {
                DAMMetaRow("Modified", modified.formatted(date: .abbreviated, time: .shortened))
            }
            if let captured = asset.captureDate {
                DAMMetaRow("Captured", captured.formatted(date: .abbreviated, time: .shortened))
            }
            if let camera = [asset.cameraMake, asset.cameraModel]
                .compactMap({ $0 }).joined(separator: " ").nilIfBlank {
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
            DAMMetaRow("Path", asset.path)
        }
    }

    @ViewBuilder
    private func keywordEditor(_ asset: DAMAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keywords")
                .font(.subheadline.weight(.semibold))
            if let current = asset.userKeywords, !current.isEmpty {
                Text("Current: \(current)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            TextField("comma, separated, keywords", text: $keywordDraft)
                .textFieldStyle(.roundedBorder)
            Picker("Mode", selection: $keywordMode) {
                ForEach(DAMViewModel.KeywordApplyMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button {
                Task {
                    await viewModel.applyUserKeywords(
                        keywordDraft, mode: keywordMode, to: viewModel.selection)
                }
            } label: {
                Text("Apply to \(viewModel.selection.count) selected")
                    .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.selection.isEmpty)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func additionalText(_ asset: DAMAsset) -> some View {
        if let xattr = asset.xattrKeywords, !xattr.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Finder Tags")
                    .font(.subheadline.weight(.semibold))
                Text(xattr).font(.caption).textSelection(.enabled)
            }
        }
        if let ai = asset.aiKeywords, !ai.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Keywords")
                    .font(.subheadline.weight(.semibold))
                Text(ai).font(.caption).textSelection(.enabled)
            }
        }
        if let caption = asset.aiCaption, !caption.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Caption")
                    .font(.subheadline.weight(.semibold))
                Text(caption).font(.caption).textSelection(.enabled)
            }
        }
    }

    private var iptcPlaceholder: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("IPTC Core")
                .font(.subheadline.weight(.semibold))
            Text("Editable IPTC/XMP fields (Creator, Title, City, Country…) arrive "
                 + "with metadata writing — Phase 2 via exiftool sidecars.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Label/value row shared by metadata displays.
struct DAMMetaRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }
}

// MARK: - Shared context menu

/// One context menu used by the grid, filmstrip, and list: Show in Finder,
/// Copy Path(s), and the audited rating submenu. Operates on the resolved
/// selection passed in by the caller.
enum DAMContextMenu {

    @ViewBuilder
    static func items(
        viewModel: DAMViewModel,
        assets: [DAMAsset],
        ids: Set<DAMAsset.ID>
    ) -> some View {
        if !assets.isEmpty {
            Button { reveal(assets) } label: {
                Label(assets.count > 1 ? "Show \(assets.count) in Finder" : "Show in Finder",
                      systemImage: "folder")
            }
            Button { copyPaths(assets) } label: {
                Label(assets.count > 1 ? "Copy \(assets.count) Paths" : "Copy Path",
                      systemImage: "doc.on.doc")
            }
            Divider()
            ForEach(0...5, id: \.self) { stars in
                Button {
                    Task { await viewModel.setRating(stars, for: ids) }
                } label: {
                    Text(stars == 0 ? "No rating" : "\(stars) ★")
                }
            }
        }
    }

    static func reveal(_ assets: [DAMAsset]) {
        NSWorkspace.shared.activateFileViewerSelecting(
            assets.map { URL(fileURLWithPath: $0.path) })
    }

    static func copyPaths(_ assets: [DAMAsset]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            assets.map(\.path).joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Helpers

private extension String {
    /// nil when blank — for optional-joined display values.
    var nilIfBlank: String? { isEmpty ? nil : self }
}
