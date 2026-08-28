import AppKit
import SwiftUI

// MARK: - MaestroDAM Output & Edit Workspaces
//
// Output — export panel: preset sidebar (built-ins + saved user presets),
//          full settings (format JPEG/PNG/HEIC/TIFF/copy, sizing, quality,
//          metadata policy none/some/all, text watermark, destination), and
//          a live per-item processing queue with cancel while running.
// Edit   — single-asset non-destructive editor (DAMEditView); multi-select
//          keeps the batch rating/keywords tools (both audited in damAudit).
//
// The actual export engine (`DAMExportService`) is nonisolated so heavy RAW
// decodes never touch the main thread; progress and per-item queue states
// are reported via @Sendable callbacks that hop back through `DAMViewModel`.

// MARK: - Export engine

enum DAMExportService {

    struct ExportResult: Sendable {
        var exported: [URL] = []
        /// (filename, reason) — e.g. offline files or unsupported EIP packages.
        var skipped: [(String, String)] = []
        /// (filename, error description)
        var failed: [(String, String)] = []
        /// True when the run was cancelled mid-queue.
        var cancelled = false
    }

    /// Per-item queue state for the processing-queue UI.
    enum ItemState: Sendable, Equatable {
        case pending
        case processing
        case done
        case skipped(String)
        case failed(String)
    }

    enum ExportError: Error, Sendable {
        case renderFailed
        case encodeFailed
    }

    private struct ExportSkip: Error {
        let reason: String
    }

    /// Export every asset, serially (full-res RAW decodes spike ~1 GB — do
    /// NOT parallelize). Checks Task.isCancelled between items — the
    /// ViewModel's cancelExport() cancels the surrounding task, remaining
    /// items stay pending and the result is marked cancelled.
    /// Progress: (completed, total, currentFilename); itemState: (index, state).
    nonisolated static func export(
        assets: [DAMAsset],
        preset: DAMExportPreset,
        destination: URL,
        progress: @Sendable (Int, Int, String) -> Void,
        itemState: @Sendable (Int, ItemState) -> Void = { _, _ in }
    ) async -> ExportResult {
        var result = ExportResult()
        try? FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)

        for (index, asset) in assets.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            progress(index, assets.count, asset.filename)
            itemState(index, .processing)
            do {
                if let url = try exportOne(asset, preset: preset, to: destination) {
                    result.exported.append(url)
                    itemState(index, .done)
                }
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch let skip as ExportSkip {
                result.skipped.append((asset.filename, skip.reason))
                itemState(index, .skipped(skip.reason))
            } catch {
                result.failed.append((asset.filename, error.localizedDescription))
                itemState(index, .failed(error.localizedDescription))
            }
        }
        progress(assets.count, assets.count, "")
        return result
    }

    private nonisolated static func exportOne(
        _ asset: DAMAsset,
        preset: DAMExportPreset,
        to destination: URL
    ) throws -> URL? {
        let source = URL(fileURLWithPath: asset.path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ExportSkip(reason: "File offline or missing")
        }

        guard preset.format.reRenders else {
            // Verbatim copy — original file, metadata and all. Watermark,
            // sizing, and metadata policy do not apply to byte copies.
            let target = uniqueURL(destination.appendingPathComponent(asset.filename))
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }

        if DAMFileKind.isZIPPackage(source) {
            throw ExportSkip(reason: "EIP package — rendered export not supported yet")
        }
        let base = (asset.filename as NSString).deletingPathExtension
            + "." + preset.format.fileExtension
        let target = uniqueURL(destination.appendingPathComponent(base))

        // Unedited full-size JPEG → JPEG with All metadata, no watermark:
        // copy through untouched (lossless + keeps everything).
        let ext = source.pathExtension.lowercased()
        let isJPEGSource = ext == "jpg" || ext == "jpeg"
        let hasRecipe = asset.id.flatMap { DAMDatabase.shared.loadEdits(assetId: $0) }
            .map { !$0.isIdentity } ?? false
        if preset.format == .jpeg, preset.maxDimension == 0,
           preset.metadata == .all, !preset.watermark.enabled,
           !hasRecipe, isJPEGSource {
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }

        // 1. Render pixels.
        let ceiling = preset.maxDimension > 0 ? preset.maxDimension : 12000
        var cgImage: CGImage
        if hasRecipe, let id = asset.id,
           let recipe = DAMDatabase.shared.loadEdits(assetId: id) {
            // Saved non-destructive edits → render the recipe (original stays
            // untouched — edits only exist in the recipe).
            cgImage = try DAMEditRenderer.renderCGImage(
                asset: asset, edit: recipe, maxPixelSize: ceiling)
        } else if DAMFileKind.isCameraRAW(source) {
            // LibRaw decode — the shim's embedded-preview rule means large
            // targets always trigger a real full-quality decode.
            let data = try RAWPreviewDecoder.jpegPreviewForRAW(
                atPath: source.path, maxPixelSize: CGFloat(ceiling))
            guard let jpegSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)
            else { throw ExportError.renderFailed }
            cgImage = decoded
        } else {
            cgImage = try loadCGImage(source: source, maxPixel: preset.maxDimension)
        }

        // 2. Enforce max dimension for every path (recipe renders come out
        //    at native resolution).
        cgImage = cgImage.downscaled(toMaxPixel: preset.maxDimension)

        // 3. Watermark (post-resize — relative size follows the output).
        if preset.watermark.enabled {
            cgImage = DAMEditRenderer.applyWatermark(cgImage, settings: preset.watermark)
        }

        // 4. Encode with format + metadata policy.
        let data = try DAMEditRenderer.encode(
            cgImage, format: preset.format, quality: preset.quality,
            sourceURL: source, metadataPolicy: preset.metadata)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// ImageIO render for non-RAW sources (JPEG/PNG/TIFF/HEIC…), optionally
    /// downscaled to `maxPixel` on the longest edge.
    private nonisolated static func loadCGImage(source: URL, maxPixel: Int) throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ExportError.renderFailed
        }
        let image: CGImage?
        if maxPixel > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }
        guard let image else { throw ExportError.renderFailed }
        return image
    }

    /// `name.jpg` → `name-2.jpg`, `name-3.jpg`… until the name is free.
    private nonisolated static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var counter = 2
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().path
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = URL(fileURLWithPath: "\(stem)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}

// MARK: - Output workspace

/// Export panel: preset sidebar (built-ins + saved user presets), full
/// settings form (format, sizing, quality, metadata policy, watermark,
/// destination), and a live processing queue while the export runs.
struct OutputWorkspaceView: View {
    var viewModel: DAMViewModel

    // MARK: Form state (mirrors the selected preset until edited)

    @State private var selectedPresetID: UUID = DAMExportPreset.builtIns[0].id
    @State private var userPresets: [DAMExportPreset] = []
    @State private var format: DAMExportPreset.Format = .jpeg
    @State private var maxDimension = 2048   // 0 = original size
    @State private var quality: Double = 0.85
    @State private var metadataPolicy: DAMExportPreset.MetadataPolicy = .some
    @State private var watermarkEnabled = false
    @State private var watermarkText = ""
    @State private var watermarkPosition = DAMExportPreset.WatermarkSettings.Position.bottomRight
    @State private var watermarkOpacity: Double = 0.6
    @State private var watermarkSize: Double = 0.03
    @State private var destinationPath = DAMExportPreset.defaultDestination
    @State private var showSaveDialog = false
    @State private var newPresetName = ""

    private let presetStore = DAMExportPresetStore()

    /// The preset built from the current form state.
    private var formPreset: DAMExportPreset {
        DAMExportPreset(
            id: selectedPresetID, name: selectedPreset?.name ?? "Custom",
            format: format, maxDimension: maxDimension, quality: quality,
            metadata: metadataPolicy,
            watermark: .init(
                enabled: watermarkEnabled, text: watermarkText,
                position: watermarkPosition, opacity: watermarkOpacity,
                relativeSize: watermarkSize),
            destinationPath: destinationPath)
    }

    private var selectedPreset: DAMExportPreset? {
        (userPresets + DAMExportPreset.builtIns).first { $0.id == selectedPresetID }
    }

    /// Form differs from the stored selected preset → offer "Update".
    private var formIsDirty: Bool {
        guard let stored = selectedPreset else { return false }
        var a = formPreset, b = stored
        a.name = ""; b.name = ""   // name isn't part of "dirty"
        return a != b
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: presets
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Export")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                List(selection: $selectedPresetID) {
                    if !userPresets.isEmpty {
                        Section("My Presets") {
                            ForEach(userPresets) { preset in
                                Label(preset.name, systemImage: "slider.horizontal.3")
                                    .tag(preset.id)
                                    .contextMenu {
                                        Button("Delete", role: .destructive) {
                                            deletePreset(preset)
                                        }
                                    }
                            }
                        }
                    }
                    Section("Built In") {
                        ForEach(DAMExportPreset.builtIns) { preset in
                            Label(preset.name, systemImage: formatIcon(preset.format))
                                .tag(preset.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 8) {
                    Button { newPresetName = ""; showSaveDialog = true } label: {
                        Label("Save as New…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Spacer()
                    if let selected = selectedPreset,
                       !DAMExportPreset.isBuiltIn(selected.id), formIsDirty {
                        Button("Update") { updatePreset(selected) }
                            .controlSize(.small)
                            .help("Save the current settings back into “\(selected.name)”")
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)

            Divider()

            // Center: summary / processing queue / result
            VStack(spacing: 14) {
                if viewModel.isExporting {
                    queuePane
                } else {
                    Spacer()
                    Image(systemName: formatIcon(format))
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(presetSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Text("\(viewModel.selection.count) item(s) selected")
                        .font(.headline)
                    if let result = viewModel.lastExportResult {
                        resultSummary(result)
                    } else {
                        Text("Select assets in the browser strip below or any workspace — "
                             + "everything selected is exported.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Right: settings
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Output Settings")
                        .font(.headline)

                    // Format
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Format")
                            .font(.subheadline.weight(.semibold))
                        Picker("Format", selection: $format) {
                            ForEach(DAMExportPreset.Format.allCases) { f in
                                Text(f.title).tag(f)
                            }
                        }
                        .labelsHidden()
                    }

                    if format.reRenders {
                        // Sizing
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Max Dimension")
                                .font(.subheadline.weight(.semibold))
                            Picker("Max dimension", selection: $maxDimension) {
                                Text("Original").tag(0)
                                Text("1024 px").tag(1024)
                                Text("2048 px").tag(2048)
                                Text("4096 px").tag(4096)
                            }
                            .labelsHidden()
                        }

                        // Quality (lossy formats only)
                        if format.supportsQuality {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Quality: \(Int(quality * 100))%")
                                    .font(.subheadline.weight(.semibold))
                                Slider(value: $quality, in: 0.5...1.0)
                                Text("RAW decodes always export at maximum quality.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // Metadata policy
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Metadata")
                                .font(.subheadline.weight(.semibold))
                            Picker("Metadata", selection: $metadataPolicy) {
                                ForEach(DAMExportPreset.MetadataPolicy.allCases) { policy in
                                    Text(policy.title).tag(policy)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            Text(metadataCaption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Watermark
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Watermark", isOn: $watermarkEnabled)
                                .toggleStyle(.checkbox)
                                .font(.subheadline.weight(.semibold))
                            if watermarkEnabled {
                                TextField("Watermark text", text: $watermarkText)
                                    .textFieldStyle(.roundedBorder)
                                Picker("Position", selection: $watermarkPosition) {
                                    ForEach(DAMExportPreset.WatermarkSettings.Position.allCases) { pos in
                                        Text(pos.title).tag(pos)
                                    }
                                }
                                .labelsHidden()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Opacity: \(Int(watermarkOpacity * 100))%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Slider(value: $watermarkOpacity, in: 0.1...1.0)
                                    Text("Size: \(Int(watermarkSize * 100))% of image edge")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Slider(value: $watermarkSize, in: 0.01...0.15)
                                }
                            }
                        }
                    } else {
                        Text("Originals are copied byte-for-byte — sizing, quality, "
                             + "metadata, and watermark settings don't apply.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Destination
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Destination")
                            .font(.subheadline.weight(.semibold))
                        Text(destinationPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Choose…") { chooseDestination() }
                            .controlSize(.small)
                    }

                    Button {
                        viewModel.exportSelection(preset: formPreset)
                    } label: {
                        Label(viewModel.isExporting ? "Exporting…" : "Start Export",
                              systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selection.isEmpty || viewModel.isExporting)
                }
                .padding(14)
            }
            .frame(width: 260)
        }
        .onAppear {
            userPresets = presetStore.load()
            if let selected = selectedPreset { loadPreset(selected) }
        }
        .onChange(of: selectedPresetID) { _, _ in
            if let selected = selectedPreset { loadPreset(selected) }
        }
        .alert("Save Export Preset", isPresented: $showSaveDialog) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { saveNewPreset() }
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the current settings as a reusable export preset.")
        }
    }

    // MARK: - Processing queue

    /// Live per-item queue while an export runs: one row per asset with its
    /// state (pending / processing / done / skipped / failed + reason).
    private var queuePane: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Exporting \(viewModel.exportProgressDone) of "
                     + "\(viewModel.exportProgressTotal)")
                    .font(.headline)
                Spacer()
                Button(role: .cancel) { viewModel.cancelExport() } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                .controlSize(.small)
            }
            ProgressView(
                value: Double(viewModel.exportProgressDone),
                total: Double(max(1, viewModel.exportProgressTotal))
            )
            Text(viewModel.exportCurrentFile)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            List(viewModel.exportQueue) { item in
                HStack(spacing: 8) {
                    queueStateIcon(item.state)
                    Text(item.filename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    switch item.state {
                    case .skipped(let reason):
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    case .failed(let reason):
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    default:
                        EmptyView()
                    }
                }
            }
            .listStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func queueStateIcon(_ state: DAMExportService.ItemState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .processing:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Helpers

    private func formatIcon(_ format: DAMExportPreset.Format) -> String {
        format == .copyOriginals ? "doc.on.doc" : "photo"
    }

    private var presetSummary: String {
        switch format {
        case .copyOriginals:
            return "Copy the original files to the destination folder, unchanged."
        default:
            return "Render the selection to \(format.title) — RAW files decode "
                 + "at full quality via LibRaw, standard images via ImageIO."
        }
    }

    private var metadataCaption: String {
        switch metadataPolicy {
        case .none:
            return "Strip everything — smallest, most private files."
        case .some:
            return "Keep camera, lens, and exposure data; drop GPS, owner "
                 + "fields, maker notes, and serial numbers."
        case .all:
            return "Re-attach the source file's full metadata verbatim."
        }
    }

    private func loadPreset(_ preset: DAMExportPreset) {
        format = preset.format
        maxDimension = preset.maxDimension
        quality = preset.quality
        metadataPolicy = preset.metadata
        watermarkEnabled = preset.watermark.enabled
        watermarkText = preset.watermark.text
        watermarkPosition = preset.watermark.position
        watermarkOpacity = preset.watermark.opacity
        watermarkSize = preset.watermark.relativeSize
        destinationPath = preset.destinationPath
    }

    private func saveNewPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var preset = formPreset
        preset.id = UUID()
        preset.name = name
        try? presetStore.upsert(preset)
        userPresets = presetStore.load()
        selectedPresetID = preset.id
    }

    private func updatePreset(_ stored: DAMExportPreset) {
        var preset = formPreset
        preset.id = stored.id
        preset.name = stored.name
        try? presetStore.upsert(preset)
        userPresets = presetStore.load()
    }

    private func deletePreset(_ preset: DAMExportPreset) {
        try? presetStore.delete(id: preset.id)
        userPresets = presetStore.load()
        if selectedPresetID == preset.id {
            selectedPresetID = DAMExportPreset.builtIns[0].id
        }
    }

    @ViewBuilder
    private func resultSummary(_ result: DAMExportService.ExportResult) -> some View {
        VStack(spacing: 6) {
            Text(result.cancelled
                 ? "Cancelled — exported \(result.exported.count) of "
                    + "\(result.exported.count + result.skipped.count + result.failed.count) file(s)"
                 : "Exported \(result.exported.count) file(s)")
                .font(.headline)
            if !result.skipped.isEmpty {
                Text("Skipped \(result.skipped.count) — \(result.skipped.first?.1 ?? "")"
                     + (result.skipped.count > 1 ? " (and more)" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !result.failed.isEmpty {
                Text("Failed \(result.failed.count) — \(result.failed.first?.1 ?? "")")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: destinationPath)])
            } label: {
                Label("Reveal Export Folder", systemImage: "folder")
            }
            .controlSize(.small)
        }
    }

    @MainActor
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose the export destination folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationPath = url.path
    }
}

// MARK: - Edit workspace

struct EditWorkspaceView: View {
    var viewModel: DAMViewModel

    /// Exactly one selected asset → the non-destructive editor; otherwise the
    /// original batch tools. Uses the canonical primary-selection resolver —
    /// `selection.first` is non-deterministic (Set rehashing) and a page-only
    /// search loses any selection outside the loaded page, so the Edit tab
    /// could show a different asset than every other workspace, or none.
    private var singleSelection: DAMAsset? {
        guard viewModel.selection.count == 1 else { return nil }
        return viewModel.primaryAsset
    }

    var body: some View {
        if let asset = singleSelection {
            DAMEditView(asset: asset, viewModel: viewModel)
        } else {
            batchWorkspace
        }
    }

    // MARK: - Batch workspace (multi-select or none)

    private enum BatchTask: String, CaseIterable, Identifiable {
        case rating = "Batch Rating"
        case keywords = "Batch Keywords"
        case redactions = "Redaction Layout"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .rating: return "star"
            case .keywords: return "tag"
            case .redactions: return "eye.slash"
            }
        }
    }

    @State private var task: BatchTask = .rating
    @State private var ratingDraft = 5
    @State private var keywordDraft = ""
    @State private var keywordMode: DAMViewModel.KeywordApplyMode = .add
    @State private var confirmation = ""
    /// Number of boxes in the redaction layout currently on the clipboard
    /// (nil = no layout copied). Refreshed when the selection changes.
    @State private var clipboardLayoutCount: Int?

    /// The original batch rating/keywords workspace, used when zero or
    /// several assets are selected.
    private var batchWorkspace: some View {
        HStack(spacing: 0) {
            // Left: task list
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Edit")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                List(selection: $task) {
                    ForEach(BatchTask.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .tag(item)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 170, idealWidth: 200, maxWidth: 240)

            Divider()

            // Center: task controls + selection strip
            VStack(spacing: 16) {
                Text("\(viewModel.selection.count) item(s) selected")
                    .font(.headline)
                    .padding(.top, 16)

                if viewModel.selection.isEmpty {
                    ContentUnavailableView(
                        "Nothing Selected",
                        systemImage: "checkmark.circle",
                        description: Text(
                            "Select assets in the browser strip below or any workspace "
                            + "(⌘-click for multiple), then apply a batch operation here.")
                    )
                } else {
                    switch task {
                    case .rating:
                        ratingControls
                    case .keywords:
                        keywordControls
                    case .redactions:
                        redactionLayoutControls
                    }
                }

                if !confirmation.isEmpty {
                    Text(confirmation)
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Batch redaction layout

    /// Paste a copied redaction layout (single image → Edit → Redact → Copy
    /// layout) onto every selected asset. Layouts are normalized 0…1, so the
    /// same boxes land proportionally on each image's frame. Existing
    /// redaction boxes on a target are REPLACED; other recipe settings
    /// (light/color/geometry) are untouched.
    private var redactionLayoutControls: some View {
        VStack(spacing: 12) {
            Text("Copy a layout from a single image first "
                 + "(Edit page → Redact → Copy layout), then apply it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let count = clipboardLayoutCount {
                Text("Clipboard: \(count) box(es)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No redaction layout on the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button {
                applyCopiedLayoutToSelection()
            } label: {
                Text("Apply layout to \(viewModel.selection.count) selected")
                    .frame(maxWidth: 260)
            }
            .disabled(clipboardLayoutCount == nil || viewModel.selection.isEmpty)
            .controlSize(.small)
        }
        .task(id: viewModel.selection) {
            refreshClipboardLayoutCount()
        }
        .onAppear { refreshClipboardLayoutCount() }
    }

    private func refreshClipboardLayoutCount() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let boxes = DAMEditState.redactionLayout(fromJSON: text)
        else {
            clipboardLayoutCount = nil
            return
        }
        clipboardLayoutCount = boxes.count
    }

    private func applyCopiedLayoutToSelection() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let boxes = DAMEditState.redactionLayout(fromJSON: text) else {
            confirmation = "No redaction layout on the clipboard."
            return
        }
        let ids = viewModel.selection.compactMap { $0 }
        Task {
            var applied = 0
            for id in ids {
                var recipe = DAMDatabase.shared.loadEdits(assetId: id) ?? DAMEditState()
                // Fresh ids per target — recipes are per-asset and box ids
                // must never collide across pastes.
                recipe.redactions = boxes.map { box in
                    var copy = box
                    copy.id = UUID()
                    return copy
                }
                try? DAMDatabase.shared.saveEdits(assetId: id, recipe)
                applied += 1
            }
            confirmation = "Applied \(boxes.count) redaction box(es) to \(applied) asset(s)."
        }
    }

    private var ratingControls: some View {
        VStack(spacing: 12) {
            Text("Set the same rating on every selected asset.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        ratingDraft = star == ratingDraft ? 0 : star
                    } label: {
                        Image(systemName: star <= ratingDraft ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(star <= ratingDraft ? .yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                let rating = ratingDraft
                confirmation = ""
                Task {
                    await viewModel.setRating(rating, for: viewModel.selection)
                    confirmation = "Rated \(viewModel.selection.count) asset(s) "
                        + (rating == 0 ? "cleared" : "\(rating) ★")
                }
            } label: {
                Text("Apply Rating to Selection")
                    .frame(width: 240)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var keywordControls: some View {
        VStack(spacing: 12) {
            Text("Add or replace user keywords on every selected asset.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("comma, separated, keywords", text: $keywordDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Picker("Mode", selection: $keywordMode) {
                ForEach(DAMViewModel.KeywordApplyMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .labelsHidden()
            Button {
                let draft = keywordDraft
                let mode = keywordMode
                confirmation = ""
                Task {
                    await viewModel.applyUserKeywords(
                        draft, mode: mode, to: viewModel.selection)
                    if viewModel.errorMessage == nil {
                        confirmation = "Keywords \(mode.rawValue.lowercased())ed on "
                            + "\(viewModel.selection.count) asset(s)"
                    }
                }
            } label: {
                Text("Apply Keywords to Selection")
                    .frame(width: 240)
            }
            .buttonStyle(.borderedProminent)
            .disabled(keywordDraft.trimmingCharacters(in: .whitespaces).isEmpty
                      && keywordMode == .add)
        }
    }
}
