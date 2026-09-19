import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - MaestroDAM Workspace Layouts
//
// Workspace tabs and the shared building blocks behind them: Home (tree +
// grid + preview), Metadata (sortable list + metadata/keywords/AI-tagging
// panel), Edit and Output (in `DAMOutputWorkflow.swift`), plus the
// resizable-panel drag handle and the unified context menu used by every
// workspace. Every page shows the persistent FilmstripBar browser strip
// mounted at the bottom of `DAMBrowserView`.

// MARK: - Workspace enum

/// Workspace layouts. Persisted via `DAMViewModel.workspace`.
/// CaseIterable order IS the tab order: Home, Metadata, Edit, Output.
/// Tab names are deliberately generic (Home/Edit, not Essentials/Workflow)
/// to avoid any Adobe look-and-feel entanglement. Removed tabs (Filmstrip,
/// Libraries, Tagging) leave legacy persisted rawValues that fall through
/// to the .home default.
enum DAMWorkspace: String, CaseIterable, Identifiable, Sendable {
    case home, metadata, edit, output

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .home: return "house"
        case .metadata: return "list.bullet.rectangle"
        case .edit: return "square.and.pencil"
        case .output: return "square.and.arrow.up"
        }
    }

    var help: String {
        switch self {
        case .home: return "Folders, thumbnail grid, and Preview + File Properties"
        case .metadata: return "Sortable list view with full metadata, keyword editing, and AI tagging"
        case .edit: return "Non-destructive editor for one asset; batch rating/keywords for many"
        case .output: return "Export the selection (JPEG render or copy originals)"
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

// MARK: - Filmstrip bar

/// Horizontal scrolling thumbnail strip synced to the selection. Mounted
/// once at the bottom of DAMBrowserView (the persistent Lightroom/Capture
/// One-style browser strip showing the loaded page on every tool page).
/// ⌘-click toggles multi-selection, like the grid.
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
    @State private var loadFailed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if loadFailed {
                Image(systemName: "doc")
                    .font(.title2)
                    .foregroundStyle(.secondary)
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
            let loaded = try await ThumbnailService.shared.redactedThumbnail(for: asset)
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

// MARK: - Metadata workspace: sortable list

/// Bridge's Content panel in list mode: sortable columns, multi-select,
/// context menu. Drives the same selection as the grid.
struct ListWorkspaceView: View {
    var viewModel: DAMViewModel

    @State private var sortOrder: [KeyPathComparator<DAMAsset>] = []

    // MARK: - Column visibility
    @AppStorage("dam.listColumn.type") private var showTypeColumn = true
    @AppStorage("dam.listColumn.rating") private var showRatingColumn = true
    @AppStorage("dam.listColumn.keywords") private var showKeywordsColumn = true
    @AppStorage("dam.listColumn.folder") private var showFolderColumn = true
    @AppStorage("dam.listColumn.duration") private var showDurationColumn = true
    @AppStorage("dam.listColumn.extension") private var showExtensionColumn = true

    private var sortedAssets: [DAMAsset] {
        sortOrder.isEmpty ? viewModel.assets : viewModel.assets.sorted(using: sortOrder)
    }

    private var selectionBinding: Binding<Set<DAMAsset.ID>> {
        Binding(
            get: { viewModel.selection },
            set: { viewModel.setSelection($0) }
        )
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 14.4, *) {
            customizableTable
        } else {
            standardTable
        }
    }

    /// macOS 14.4+ supports conditional `TableColumn` declarations, so we can
    /// let the user show/hide columns and persist the choices in AppStorage.
    @available(macOS 14.4, *)
    private var customizableTable: some View {
        ZStack(alignment: .topTrailing) {
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

                if showExtensionColumn {
                    TableColumn("Ext", value: \.sortExtension) { asset in
                        Text(asset.formattedExtension)
                            .lineLimit(1)
                    }
                    .width(60)
                }

                if showTypeColumn {
                    TableColumn("Type", value: \.sortType) { asset in
                        Text(UTType(asset.uti ?? "")?.localizedDescription
                             ?? (asset.path as NSString).pathExtension.uppercased())
                            .lineLimit(1)
                    }
                    .width(110)
                }

                if showDurationColumn {
                    TableColumn("Duration", value: \.sortDuration) { asset in
                        Text(asset.formattedDuration)
                            .monospacedDigit()
                    }
                    .width(80)
                }

                if showRatingColumn {
                    TableColumn("Rating", value: \.rating) { asset in
                        Text(asset.rating == 0 ? "—" : String(repeating: "★", count: asset.rating))
                            .foregroundStyle(.yellow)
                    }
                    .width(70)
                }

                if showKeywordsColumn {
                    TableColumn("Keywords") { asset in
                        Text(asset.userKeywords ?? asset.xattrKeywords ?? "")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                if showFolderColumn {
                    TableColumn("Folder") { asset in
                        Text(asset.folder ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .contextMenu(forSelectionType: DAMAsset.ID.self) { ids in
                DAMContextMenu.items(
                    viewModel: viewModel,
                    assets: viewModel.assets.filter { ids.contains($0.id ?? -1) },
                    ids: ids)
            }

            columnPicker
                .padding(.top, 6)
                .padding(.trailing, 16)
        }
    }

    /// Fallback for macOS 14.0–14.3: all columns are always visible because
    /// conditional TableColumn builder support requires macOS 14.4.
    private var standardTable: some View {
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

            TableColumn("Ext", value: \.sortExtension) { asset in
                Text(asset.formattedExtension)
                    .lineLimit(1)
            }
            .width(60)

            TableColumn("Type", value: \.sortType) { asset in
                Text(UTType(asset.uti ?? "")?.localizedDescription
                     ?? (asset.path as NSString).pathExtension.uppercased())
                    .lineLimit(1)
            }
            .width(110)

            TableColumn("Duration", value: \.sortDuration) { asset in
                Text(asset.formattedDuration)
                    .monospacedDigit()
            }
            .width(80)

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

    @available(macOS 14.4, *)
    private var columnPicker: some View {
        Menu {
            Toggle("Extension", isOn: $showExtensionColumn)
            Toggle("Type", isOn: $showTypeColumn)
            Toggle("Duration", isOn: $showDurationColumn)
            Toggle("Rating", isOn: $showRatingColumn)
            Toggle("Keywords", isOn: $showKeywordsColumn)
            Toggle("Folder", isOn: $showFolderColumn)
        } label: {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28, height: 20)
        .help("Show or hide list columns")
    }
}

// MARK: - Metadata panel (Metadata workspace left column / shared rows)

/// Full metadata + user-keyword editing for the primary selection.
/// Keyword writes go through `DAMViewModel.applyUserKeywords` (audited).
/// Also hosts AI tagging (the retired Tagging workspace's home): catalog
/// indexing controls plus accept/reject of pending suggestions for the
/// current selection — backed by `DAMTaggingViewModel`/`DAMTaggingService`.
struct MetadataPanelView: View {
    var viewModel: DAMViewModel

    @State private var keywordDraft = ""
    @State private var keywordMode: DAMViewModel.KeywordApplyMode = .add
    @State private var tagging = DAMTaggingViewModel()
    @State private var assetSuggestions: [DAMTagSuggestion] = []
    @State private var engine = MediaPlayerEngine.shared

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
                        if isPlayable(asset) {
                            playbackSection(asset)
                        }
                        keywordEditor(asset)
                        aiTagging(asset)
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
            await refreshSuggestions()
        }
        // Once per panel appearance: the catalog-wide indexing counters.
        .task { await tagging.refreshCounts() }
    }

    /// True for audio/video assets that can be played by the built-in player.
    private func isPlayable(_ asset: DAMAsset) -> Bool {
        let url = URL(fileURLWithPath: asset.path)
        return DAMFileKind.isAudio(url) || DAMFileKind.isVideo(url)
    }

    /// Inline playback controls for the selected audio/video asset. Loads the
    /// file into the shared MediaPlayerEngine and stays inside MaestroDAM —
    /// no separate app required.
    @ViewBuilder
    private func playbackSection(_ asset: DAMAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playback")
                .font(.subheadline.weight(.semibold))

            let isLoaded = engine.currentURL?.path == asset.path

            if isLoaded {
                MediaPlayerProgressBar(
                    currentTime: engine.currentTime,
                    duration: engine.duration ?? 0,
                    isSeeking: engine.isSeeking,
                    onSeek: { engine.seek(to: $0) }
                )

                MediaPlayerTransportView(
                    isPlaying: engine.isPlaying,
                    hasItem: engine.hasItem,
                    onPlayPause: { engine.togglePlayPause() },
                    onSkipBack: { engine.skipBackward() },
                    onSkipForward: { engine.skipForward() },
                    onSeekBackward15: { engine.seekRelative(-15) },
                    onSeekForward15: { engine.seekRelative(15) }
                )
            } else {
                HStack(spacing: 8) {
                    Button {
                        let url = URL(fileURLWithPath: asset.path)
                        if DAMFileKind.isVideo(url) {
                            // Video preview is the Quick Look panel (same as
                            // the spacebar shortcut in the browser).
                            DAMQuickLookPanelController.shared.toggle(for: url)
                        } else {
                            Task {
                                await engine.load(url: url)
                                engine.play()
                            }
                        }
                    } label: {
                        Label("Play", systemImage: "play.circle")
                    }

                    if FileManager.default.fileExists(atPath: "/Applications/VLC.app") {
                        Button {
                            let url = URL(fileURLWithPath: asset.path)
                            let vlc = URL(fileURLWithPath: "/Applications/VLC.app")
                            NSWorkspace.shared.open([url], withApplicationAt: vlc, configuration: NSWorkspace.OpenConfiguration())
                        } label: {
                            Label("Open in VLC", systemImage: "play.tv")
                        }
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// Reload the pending AI suggestions for the current primary selection.
    private func refreshSuggestions() async {
        guard let id = viewModel.primaryAsset?.id else {
            assetSuggestions = []
            return
        }
        assetSuggestions = await tagging.suggestions(forAssetId: id)
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
                .onSubmit {
                    Task { await applyKeywords(mode: .add) }
                }
            HStack(spacing: 8) {
                Button {
                    Task { await applyKeywords(mode: .add) }
                } label: {
                    Text("Add")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.selection.isEmpty || keywordDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    Task { await applyKeywords(mode: .replace) }
                } label: {
                    Text("Replace")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.selection.isEmpty || keywordDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
    }

    private func applyKeywords(mode: DAMViewModel.KeywordApplyMode) async {
        await viewModel.applyUserKeywords(
            keywordDraft, mode: mode, to: viewModel.selection)
        if viewModel.errorMessage == nil {
            keywordDraft = ""
        }
    }

    /// AI tagging, living on the Metadata page (its proper home): indexing
    /// controls for the catalog-wide analysis pass, accept/reject of the
    /// pending suggestions for the CURRENT selection, and scoped generative
    /// tagging for selections, folders, and albums. Accepted suggestions
    /// become real tags (mirrored to userKeywords) and new exemplars — the
    /// engine learns as you confirm.
    @ViewBuilder
    private func aiTagging(_ asset: DAMAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI Tagging")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if tagging.isIndexing {
                    Button(role: .cancel) { tagging.cancelIndexing() } label: {
                        Label("Stop", systemImage: "xmark.circle")
                    }
                    .controlSize(.small)
                } else {
                    Button { tagging.startIndexing() } label: {
                        Label("Index", systemImage: "sparkles.rectangle.stack")
                    }
                    .controlSize(.small)
                    .help("Analyze the catalog (OCR + visual fingerprints) "
                          + "so tags can be suggested for similar images")
                }
            }

            HStack {
                Spacer()
                Menu {
                    Button {
                        Task {
                            let assets = await viewModel.assets(for: viewModel.selection)
                            if await tagging.generateTags(for: assets) != nil {
                                await viewModel.reload()
                                await refreshSuggestions()
                                await tagging.refreshCounts()
                            }
                        }
                    } label: {
                        Label(
                            viewModel.selection.count <= 1
                                ? "Generate Tags for Selection"
                                : "Generate Tags for \(viewModel.selection.count) Selected",
                            systemImage: "sparkles")
                    }
                    .disabled(viewModel.selection.isEmpty || tagging.isGenerating)

                    if let folder = viewModel.selectedFolder {
                        Button {
                            Task {
                                _ = await tagging.generateTags(forFolder: folder)
                                await viewModel.reload()
                                await refreshSuggestions()
                                await tagging.refreshCounts()
                            }
                        } label: {
                            Label("Generate Tags for Folder", systemImage: "folder.badge.sparkles")
                        }
                        .disabled(tagging.isGenerating)
                    }
                } label: {
                    Label("Generate Tags", systemImage: "sparkles")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(tagging.isGenerating)
                .help("Generate AI tags for the selection or current folder")

                Button(role: .destructive) {
                    Task {
                        let assets = await viewModel.assets(for: viewModel.selection)
                        await tagging.clearAITags(for: assets)
                        await viewModel.reload()
                        await refreshSuggestions()
                        await tagging.reload()
                        await tagging.refreshCounts()
                    }
                } label: {
                    Label("Clear AI Tags", systemImage: "eraser")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(viewModel.selection.isEmpty || tagging.isGenerating)
                .help("Remove all AI-generated tags and captions from the selection")
            }

            Toggle(
                "Use LLM for audio captions",
                isOn: Binding(
                    get: { DAMTaggingService.useLLMForAudioCaptions },
                    set: { DAMTaggingService.useLLMForAudioCaptions = $0 }
                )
            )
            .controlSize(.small)
            .font(.caption)
            .help("Slower but writes polished captions and better tags from audio transcripts")

            videoTaggingOptions

            if tagging.isGenerating || tagging.isIndexing {
                let message = tagging.isGenerating
                    ? (tagging.generateProgress.isEmpty ? "Generating tags…" : tagging.generateProgress)
                    : (tagging.indexProgress.isEmpty ? "Indexing catalog…" : tagging.indexProgress)
                RetroScanIndicator(message: message)
                    .padding(.vertical, 8)
            } else if tagging.backlogCount > 0 {
                Text("\(tagging.backlogCount) assets waiting to be indexed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let status = tagging.statusMessage {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if assetSuggestions.isEmpty {
                Text("No suggestions for this asset — tag a few similar images, "
                     + "then run Index so matches can be found.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(assetSuggestions) { suggestion in
                    HStack(spacing: 6) {
                        Image(systemName: DAMTaggingViewModel.basisIcon(suggestion.basis))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(DAMTaggingViewModel.basisLabel(suggestion.basis))
                        Text(suggestion.tagName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(Int((suggestion.confidence * 100).rounded()))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button {
                            Task {
                                await tagging.accept(suggestion)
                                await refreshSuggestions()
                            }
                        } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.green)
                        .help("Accept “\(suggestion.tagName)”")
                        Button {
                            Task {
                                await tagging.reject(suggestion)
                                await refreshSuggestions()
                            }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Reject “\(suggestion.tagName)”")
                    }
                }
            }
        }
    }

    private var videoTaggingOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Tag video frames visually",
                isOn: Binding(
                    get: { DAMTaggingService.useVisionForVideoTags },
                    set: { DAMTaggingService.useVisionForVideoTags = $0 }
                )
            )
            .controlSize(.small)
            .font(.caption)
            .help("Extract video frames and caption them with the on-device vision model")

            if DAMTaggingService.useVisionForVideoTags {
                HStack(spacing: 12) {
                    Picker("Frame interval", selection: frameIntervalBinding) {
                        Text("30 sec").tag(0.5)
                        Text("1 min").tag(1.0)
                        Text("2 min").tag(2.0)
                        Text("5 min").tag(5.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .accessibilityLabel("Frame interval")

                    Stepper(
                        value: maxFramesBinding,
                        in: 10...120,
                        step: 10
                    ) {
                        Text("Max \(DAMTaggingService.videoTaggingConfig.maxFrames) frames")
                            .font(.caption)
                    }
                    .accessibilityLabel("Maximum frames")
                }
            }
        }
    }

    private var frameIntervalBinding: Binding<Double> {
        Binding(
            get: { DAMTaggingService.videoTaggingConfig.frameIntervalMinutes },
            set: { newValue in
                var config = DAMTaggingService.videoTaggingConfig
                config.frameIntervalMinutes = newValue
                DAMTaggingService.videoTaggingConfig = config
            }
        )
    }

    private var maxFramesBinding: Binding<Int> {
        Binding(
            get: { DAMTaggingService.videoTaggingConfig.maxFrames },
            set: { newValue in
                var config = DAMTaggingService.videoTaggingConfig
                config.maxFrames = newValue
                DAMTaggingService.videoTaggingConfig = config
            }
        )
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
            Button {
                Task { await viewModel.generateTags(for: ids) }
            } label: {
                Label(ids.count > 1 ? "Generate Tags for \(ids.count)" : "Generate Tags",
                      systemImage: "sparkles")
            }
            Divider()
            ForEach(0...5, id: \.self) { stars in
                Button {
                    Task { await viewModel.setRating(stars, for: ids) }
                } label: {
                    Text(stars == 0 ? "No rating" : "\(stars) ★")
                }
            }

            let playableURLs = assets.compactMap { asset -> URL? in
                let url = URL(fileURLWithPath: asset.path)
                return MediaPlayerFormat.canPlay(url) ? url : nil
            }
            if !playableURLs.isEmpty {
                Divider()
                Button {
                    Task { @MainActor in
                        MediaPlayerQueue.shared.append(contentsOf: playableURLs)
                    }
                } label: {
                    Label(
                        playableURLs.count > 1
                            ? "Add \(playableURLs.count) to Media Player Playlist"
                            : "Add to Media Player Playlist",
                        systemImage: "music.note.list"
                    )
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
