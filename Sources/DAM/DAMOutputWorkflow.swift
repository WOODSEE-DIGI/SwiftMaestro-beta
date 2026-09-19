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
                if let url = try exportOne(asset, index: index, preset: preset, to: destination) {
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
        index: Int,
        preset: DAMExportPreset,
        to destination: URL
    ) throws -> URL? {
        let source = URL(fileURLWithPath: asset.path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ExportSkip(reason: "File offline or missing")
        }

        let secureRedacted = preset.secureRedacted == true
        let originalBase = (asset.filename as NSString).deletingPathExtension
        let exportExt = preset.format.reRenders
            ? preset.format.fileExtension
            : source.pathExtension

        guard preset.format.reRenders else {
            // Verbatim copy — original file, metadata and all. Watermark,
            // sizing, and metadata policy do not apply to byte copies.
            // Secure redacted exports MUST re-render, so they never take this path.
            if secureRedacted {
                throw ExportSkip(reason: "Secure redacted export requires a rendered format")
            }
            let filename = exportFilename(
                mode: preset.exportNamingMode,
                jobName: preset.exportJobName,
                originalBase: originalBase,
                index: index,
                extension: exportExt)
            let target = uniqueURL(destination.appendingPathComponent(filename))
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }

        if DAMFileKind.isZIPPackage(source) {
            throw ExportSkip(reason: "EIP package — rendered export not supported yet")
        }
        let base = exportFilename(
            mode: preset.exportNamingMode,
            jobName: preset.exportJobName,
            originalBase: originalBase,
            index: index,
            extension: preset.format.fileExtension)
        let target = uniqueURL(destination.appendingPathComponent(base))

        // Unedited full-size JPEG → JPEG with All metadata, no watermark:
        // copy through untouched (lossless + keeps everything).
        let ext = source.pathExtension.lowercased()
        let isJPEGSource = ext == "jpg" || ext == "jpeg"
        let hasRecipe = asset.id.flatMap { DAMDatabase.shared.loadEdits(assetId: $0) }
            .map { !$0.isIdentity } ?? false
        if preset.format == .jpeg, preset.maxDimension == 0,
           preset.metadata == .all, !preset.watermark.enabled,
           !hasRecipe, !secureRedacted, isJPEGSource {
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }

        // 1. Render pixels.
        let ceiling = preset.maxDimension > 0 ? preset.maxDimension : 12000
        var cgImage: CGImage
        if hasRecipe, let id = asset.id,
           let recipe = DAMDatabase.shared.loadEdits(assetId: id) {
            // Saved non-destructive edits → render the recipe (original stays
            // untouched — edits only exist in the recipe). Hidden redaction
            // layers are stripped before export so they can never leak.
            cgImage = try DAMEditRenderer.renderCGImage(
                asset: asset, edit: recipe.forExport(), maxPixelSize: ceiling)
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
            cgImage = DAMEditRenderer.applyWatermark(cgImage, settings: preset.watermark.sanitized())
        }

        // 4. Encode with format + metadata policy.
        // Secure redacted exports always strip metadata, regardless of the
        // preset's metadata policy, so no EXIF/IPTC/GPS can leak.
        let metadataPolicy: DAMExportPreset.MetadataPolicy = secureRedacted ? .none : preset.metadata
        let data = try DAMEditRenderer.encode(
            cgImage, format: preset.format, quality: preset.quality,
            sourceURL: source, metadataPolicy: metadataPolicy)
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

    /// Build an exported filename from the preset naming mode.
    nonisolated static func exportFilename(
        mode: DAMExportPreset.NamingMode,
        jobName: String,
        originalBase: String,
        index: Int,
        extension: String
    ) -> String {
        let stem: String
        switch mode {
        case .original:
            stem = originalBase
        case .jobNameOriginal:
            let prefix = jobName.trimmingCharacters(in: .whitespaces)
            stem = prefix.isEmpty ? originalBase : "\(prefix)_\(originalBase)"
        case .jobNameSequence:
            let prefix = jobName.trimmingCharacters(in: .whitespaces)
            let seq = String(format: "%04d", index + 1)
            stem = prefix.isEmpty ? seq : "\(prefix)_\(seq)"
        }
        let ext = `extension`.trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? stem : "\(stem).\(ext)"
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
    @State private var secureRedacted = false
    @State private var watermarkEnabled = false
    @State private var watermarkKind: DAMExportPreset.WatermarkSettings.Kind = .text
    @State private var watermarkText = ""
    @State private var watermarkImagePath: String? = nil
    @State private var watermarkImageBookmark: Data? = nil
    @State private var watermarkPosition = DAMExportPreset.WatermarkSettings.Position.bottomRight
    @State private var watermarkOpacity: Double = 0.6
    @State private var watermarkSize: Double = 0.03
    @State private var watermarkMargin: Double = 0.02
    @State private var watermarkPreview: NSImage?
    @State private var watermarkPreviewTask: Task<Void, Never>?
    @State private var destinationPath = DAMExportPreset.defaultDestination
    @State private var exportJobName = ""
    @State private var exportNamingMode: DAMExportPreset.NamingMode = .original
    @State private var showSaveDialog = false
    @State private var newPresetName = ""

    private let presetStore = DAMExportPresetStore()

    /// The preset built from the current form state.
    private var formPreset: DAMExportPreset {
        DAMExportPreset(
            id: selectedPresetID, name: selectedPreset?.name ?? "Custom",
            format: format, maxDimension: maxDimension, quality: quality,
            metadata: metadataPolicy, secureRedacted: secureRedacted,
            watermark: .init(
                enabled: watermarkEnabled, kind: watermarkKind, text: watermarkText,
                imagePath: watermarkImagePath, imageBookmark: watermarkImageBookmark,
                position: watermarkPosition, opacity: watermarkOpacity,
                relativeSize: watermarkSize, margin: watermarkMargin),
            destinationPath: destinationPath,
            exportJobName: exportJobName,
            exportNamingMode: exportNamingMode)
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
        VStack(spacing: 0) {
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

            // Center: watermark preview, summary, or processing queue
            VStack(spacing: 14) {
                if viewModel.isExporting {
                    queuePane
                } else if watermarkEnabled, viewModel.selection.count == 1, watermarkPreview != nil {
                    watermarkPreviewArea
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
                            HStack {
                                Text("Max Dimension")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if maxDimension == 0 {
                                    Text("Original")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    TextField(
                                        "Pixels",
                                        value: $maxDimension,
                                        formatter: maxDimensionFormatter
                                    )
                                    .frame(width: 56)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                                    Text("px")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if maxDimension > 0 {
                                Slider(
                                    value: maxDimensionSliderBinding,
                                    in: 512...8192,
                                    step: 64
                                )
                            }

                            HStack(spacing: 6) {
                                dimensionPresetButton("Original", value: 0)
                                dimensionPresetButton("1024", value: 1024)
                                dimensionPresetButton("2048", value: 2048)
                                dimensionPresetButton("4096", value: 4096)
                                dimensionPresetButton("8192", value: 8192)
                            }
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
                            .disabled(secureRedacted)
                            Text(metadataCaption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Secure redacted export
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Flatten redactions", isOn: $secureRedacted)
                                .toggleStyle(.checkbox)
                                .font(.subheadline.weight(.semibold))
                            Text(secureRedacted
                                 ? "Exports are re-rendered, all metadata is stripped, and redactions are baked into pixels — the original image cannot be recovered from the exported file."
                                 : "When enabled, exports are flattened so redactions cannot be removed and metadata is stripped.")
                                .font(.caption2)
                                .foregroundStyle(secureRedacted ? .orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Watermark
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Watermark", isOn: $watermarkEnabled)
                                .toggleStyle(.checkbox)
                                .font(.subheadline.weight(.semibold))
                            if watermarkEnabled {
                                Picker("Type", selection: $watermarkKind) {
                                    ForEach(DAMExportPreset.WatermarkSettings.Kind.allCases) { kind in
                                        Text(kind.title).tag(kind)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                switch watermarkKind {
                                case .text:
                                    TextField("Watermark text", text: $watermarkText)
                                        .textFieldStyle(.roundedBorder)
                                case .image:
                                    HStack(spacing: 8) {
                                        if let path = watermarkImagePath {
                                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                                .font(.caption)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        } else {
                                            Text("No image selected")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button("Choose…") { chooseWatermarkImage() }
                                            .controlSize(.small)
                                    }
                                }

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
                                    Slider(value: $watermarkSize, in: 0.01...1.0)
                                    Text("Margin: \(Int(watermarkMargin * 100))% of image edge")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Slider(value: $watermarkMargin, in: 0.0...0.25)
                                }

                                // Live preview + visual position pad.
                                watermarkPreviewPane
                            }
                        }
                        .task(id: watermarkPreviewTrigger) {
                            scheduleWatermarkPreviewUpdate()
                        }
                    } else {
                        Text("Originals are copied byte-for-byte — sizing, quality, "
                             + "metadata, and watermark settings don't apply.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // File naming
                    VStack(alignment: .leading, spacing: 6) {
                        Text("File Naming")
                            .font(.subheadline.weight(.semibold))
                        Picker("Naming", selection: $exportNamingMode) {
                            ForEach(DAMExportPreset.NamingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()

                        if exportNamingMode != .original {
                            TextField("Job name", text: $exportJobName)
                                .textFieldStyle(.roundedBorder)
                        }

                        Text(namingSample)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
        Divider()
        FilmstripBar(viewModel: viewModel, assets: viewModel.assets)
            .frame(height: 128)
    }
    .onAppear {
        userPresets = presetStore.load()
            if let selected = selectedPreset { loadPreset(selected) }
        }
        .onChange(of: selectedPresetID) { _, _ in
            if let selected = selectedPreset { loadPreset(selected) }
        }
        .onChange(of: secureRedacted) { _, newValue in
            if newValue {
                metadataPolicy = .none
                if !format.reRenders { format = .jpeg }
            }
        }
        .onChange(of: format) { _, newValue in
            if !newValue.reRenders { secureRedacted = false }
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

    private var namingSample: String {
        let ext = format.reRenders ? format.fileExtension : "jpg"
        let sample = DAMExportService.exportFilename(
            mode: exportNamingMode,
            jobName: exportJobName,
            originalBase: "IMG_1234",
            index: 0,
            extension: ext)
        return "Example: \(sample)"
    }

    private var maxDimensionFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 16384
        return formatter
    }

    private var maxDimensionSliderBinding: Binding<Double> {
        Binding(
            get: { Double(max(maxDimension, 512)) },
            set: { maxDimension = max(512, Int($0.rounded())) }
        )
    }

    private func dimensionPresetButton(_ title: String, value: Int) -> some View {
        Button {
            maxDimension = value
        } label: {
            Text(title)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(maxDimension == value)
    }

    private func loadPreset(_ preset: DAMExportPreset) {
        format = preset.format
        maxDimension = preset.maxDimension
        quality = preset.quality
        metadataPolicy = preset.metadata
        secureRedacted = preset.secureRedacted == true
        watermarkEnabled = preset.watermark.enabled
        watermarkKind = preset.watermark.kind
        watermarkText = preset.watermark.text
        watermarkImagePath = preset.watermark.imagePath
        watermarkImageBookmark = preset.watermark.imageBookmark
        watermarkPosition = preset.watermark.position
        watermarkOpacity = preset.watermark.opacity
        watermarkSize = preset.watermark.relativeSize
        watermarkMargin = preset.watermark.margin
        destinationPath = preset.destinationPath
        exportJobName = preset.exportJobName
        exportNamingMode = preset.exportNamingMode
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

    // MARK: - Watermark preview

    private var watermarkPreviewArea: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                if let preview = watermarkPreview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 720, maxHeight: 520)
                        .cornerRadius(8)
                } else {
                    ProgressView("Loading preview…")
                        .controlSize(.small)
                }
                Spacer()
            }

            Text("\(viewModel.selection.count) item(s) selected · watermark preview")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var watermarkPreviewPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Position")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Visual 3x3 position pad.
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    watermarkPositionButton(.topLeft, icon: "arrow.up.left")
                    Spacer()
                    watermarkPositionButton(.topRight, icon: "arrow.up.right")
                }
                HStack(spacing: 4) {
                    Spacer()
                    watermarkPositionButton(.center, icon: "dot.square")
                    Spacer()
                }
                HStack(spacing: 4) {
                    watermarkPositionButton(.bottomLeft, icon: "arrow.down.left")
                    Spacer()
                    watermarkPositionButton(.bottomRight, icon: "arrow.down.right")
                }
            }
            .frame(width: 80)
        }
    }

    private func watermarkPositionButton(
        _ position: DAMExportPreset.WatermarkSettings.Position,
        icon: String
    ) -> some View {
        Button {
            watermarkPosition = position
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24)
                .foregroundStyle(watermarkPosition == position ? Color.white : Color.primary)
                .background(
                    watermarkPosition == position
                        ? Color.accentColor
                        : Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
        .help(position.title)
    }

    private var watermarkPreviewTrigger: String {
        let assetID = viewModel.primaryAsset?.id.map(String.init) ?? "none"
        return "\(watermarkEnabled)-\(watermarkKind)-\(watermarkText)-\(watermarkImagePath ?? "")-\(watermarkPosition)-\(watermarkOpacity)-\(watermarkSize)-\(watermarkMargin)-\(assetID)"
    }

    private func scheduleWatermarkPreviewUpdate() {
        watermarkPreviewTask?.cancel()
        watermarkPreviewTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await updateWatermarkPreview()
        }
    }

    private func updateWatermarkPreview() async {
        guard watermarkEnabled,
              let asset = viewModel.primaryAsset,
              let assetId = asset.id
        else {
            await MainActor.run { watermarkPreview = nil }
            return
        }

        let settings = formPreset.watermark.sanitized()
        let previewMaxPixel = 320

        // Load the recipe on the main actor before detaching —
        // DAMDatabase is Sendable but not an actor, so avoid concurrent reads.
        let recipe = await MainActor.run {
            DAMDatabase.shared.loadEdits(assetId: assetId) ?? DAMEditState()
        }

        let image = await Task.detached(priority: .userInitiated) {
            guard let cgImage = try? DAMEditRenderer.renderCGImage(
                asset: asset, edit: recipe, maxPixelSize: previewMaxPixel),
                  cgImage.width > 0, cgImage.height > 0
            else { return nil as NSImage? }
            let watermarked = DAMEditRenderer.applyWatermark(cgImage, settings: settings)
            guard watermarked.width > 0, watermarked.height > 0 else { return nil as NSImage? }
            return NSImage(
                cgImage: watermarked,
                size: NSSize(width: watermarked.width, height: watermarked.height))
        }.value

        guard !Task.isCancelled else { return }
        await MainActor.run { watermarkPreview = image }
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

    @MainActor
    private func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.message = "Choose a watermark image"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        watermarkImagePath = url.path
        // Create a security-scoped bookmark for persistence across launches.
        watermarkImageBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                mainContent
            }
            Divider()
            FilmstripBar(viewModel: viewModel, assets: viewModel.assets)
                .frame(height: 128)
        }
    }

    // MARK: - Sidebar (always visible)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Edit")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            let canEditSingle = singleSelection != nil
            List(selection: $task) {
                ForEach(EditTask.allCases) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .tag(item)
                        .disabled(item == .singleAsset && !canEditSingle)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 28)
        }
        .frame(minWidth: 170, idealWidth: 200, maxWidth: 240)
    }

    // MARK: - Main content area

    /// Non-optional task for switches; a nil selection falls back to the
    /// single-asset editor so the UI is never in an undefined state.
    private var activeTask: EditTask { task ?? .singleAsset }

    @ViewBuilder
    private var mainContent: some View {
        switch activeTask {
        case .singleAsset:
            if let asset = singleSelection {
                DAMEditView(asset: asset, viewModel: viewModel)
            } else {
                ContentUnavailableView(
                    "Select One Asset",
                    systemImage: "photo",
                    description: Text(
                        "Select a single asset in the filmstrip below to use the non-destructive editor.")
                )
            }
        case .rating, .keywords, .redactions:
            batchTaskContent
        }
    }

    private var batchTaskContent: some View {
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
                switch activeTask {
                case .rating:
                    ratingControls
                case .keywords:
                    keywordControls
                case .redactions:
                    redactionLayoutControls
                case .singleAsset:
                    EmptyView()
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

    // MARK: - Edit tasks

    private enum EditTask: String, CaseIterable, Identifiable, Hashable {
        case singleAsset = "Edit"
        case rating = "Batch Rating"
        case keywords = "Batch Keywords"
        case redactions = "Redaction Layout"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .singleAsset: return "slider.horizontal.3"
            case .rating: return "star"
            case .keywords: return "tag"
            case .redactions: return "eye.slash"
            }
        }
    }

    @State private var task: EditTask? = .singleAsset
    @State private var ratingDraft = 5
    @State private var keywordDraft = ""
    @State private var keywordMode: DAMViewModel.KeywordApplyMode = .add
    @State private var confirmation = ""
    @State private var batchAIOptions = DAMRedactionDetectorService.Options()
    /// User-defined regex patterns for batch AI redaction, one per line.
    @State private var batchCustomPatternText: String = ""
    /// Number of boxes in the redaction layout currently on the clipboard
    /// (nil = no layout copied). Refreshed when the selection changes.
    @State private var clipboardLayoutCount: Int?

    // MARK: - Batch redaction layout

    /// Paste a copied redaction layout (single image → Edit → Redact → Copy
    /// layout) onto every selected asset. Layouts are normalized 0…1, so the
    /// same boxes land proportionally on each image's frame. Existing
    /// redaction boxes on a target are REPLACED; other recipe settings
    /// (light/color/geometry) are untouched.

    /// Split the batch custom-pattern editor text into non-empty regex strings.
    private func batchCustomPatterns(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

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

            Divider()

            Text("Or let on-device AI detect sensitive regions on every selected image.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            DisclosureGroup("AI Options") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Faces", isOn: $batchAIOptions.detectFaces)
                        .toggleStyle(.checkbox)
                    Toggle("Text / OCR", isOn: $batchAIOptions.detectText)
                        .toggleStyle(.checkbox)
                    Toggle("Barcodes & QR", isOn: $batchAIOptions.detectBarcodes)
                        .toggleStyle(.checkbox)

                    HStack {
                        Text("Confidence")
                            .font(.caption)
                        Slider(value: $batchAIOptions.minimumConfidence, in: 0.05...0.95)
                        Text(String(format: "%.0f%%", batchAIOptions.minimumConfidence * 100))
                            .font(.caption.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    }

                    if batchAIOptions.detectText {
                        let builtIn = DAMRedactionDetectorService.Options.piiPatterns
                        let custom = batchCustomPatterns(from: batchCustomPatternText)

                        Toggle("Built-in PII patterns", isOn: Binding(
                            get: { batchAIOptions.textPatterns.contains(where: builtIn.contains) },
                            set: { useBuiltIn in
                                batchAIOptions.textPatterns = useBuiltIn
                                    ? Array(Set(builtIn + custom))
                                    : custom
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .help("Email, phone, date, address, VIN, rego, SSN, ABN, ACN, TFN, CRN, Medicare, passport, licence, bank account, certificate/transaction IDs")

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom regex patterns (one per line)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $batchCustomPatternText)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 44, idealHeight: 70, maxHeight: 120)
                                .border(Color.secondary.opacity(0.2), width: 1)
                                .cornerRadius(4)
                                .onChange(of: batchCustomPatternText) { _, _ in
                                    let patterns = batchCustomPatterns(from: batchCustomPatternText)
                                    let useBuiltIn = batchAIOptions.textPatterns.contains(where: builtIn.contains)
                                    batchAIOptions.textPatterns = useBuiltIn
                                        ? Array(Set(builtIn + patterns))
                                        : patterns
                                    DAMCustomPatternStore.shared.save(patterns)
                                }
                        }
                    }
                }
            }
            .font(.caption)

            Button {
                applyAIRedactionToSelection()
            } label: {
                Label("AI Redact \(viewModel.selection.count) selected", systemImage: "wand.and.rays")
                    .frame(maxWidth: 260)
            }
            .disabled(viewModel.selection.isEmpty)
            .controlSize(.small)
        }
        .task(id: viewModel.selection) {
            refreshClipboardLayoutCount()
        }
        .onAppear {
            refreshClipboardLayoutCount()
            let custom = DAMCustomPatternStore.shared.load()
            batchCustomPatternText = custom.joined(separator: "\n")
            batchAIOptions.textPatterns = custom
        }
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
                // Ensure a default layer exists even on empty recipes so the
                // pasted batch lands in its own toggleable layer.
                _ = recipe.defaultRedactionLayerID()
                let batchLayer = DAMEditState.RedactionLayer(name: "Batch Redactions")
                recipe.redactionLayers.append(batchLayer)
                // Fresh ids per target — recipes are per-asset and box ids
                // must never collide across pastes.
                let pasted = boxes.map { box -> DAMEditState.RedactionBox in
                    var copy = box
                    copy.id = UUID()
                    copy.layerID = batchLayer.id
                    return copy
                }
                recipe.redactions.append(contentsOf: pasted)
                try? DAMDatabase.shared.saveEdits(assetId: id, recipe)
                applied += 1
            }
            confirmation = "Applied \(boxes.count) redaction box(es) to \(applied) asset(s)."
        }
    }

    /// Run on-device AI redaction on every selected asset. Each asset gets a
    /// new "AI Detected" layer so the results are reviewable per-image.
    private func applyAIRedactionToSelection() {
        let ids = viewModel.selection.compactMap { $0 }
        let assets = viewModel.assets.filter { asset in
            ids.contains(where: { $0 == asset.id })
        }
        Task {
            var applied = 0
            var totalBoxes = 0
            let options = batchAIOptions
            for asset in assets {
                guard FileManager.default.fileExists(atPath: asset.path),
                      let assetId = asset.id else { continue }
                var recipe = DAMDatabase.shared.loadEdits(assetId: assetId) ?? DAMEditState()
                _ = recipe.defaultRedactionLayerID()
                let aiLayer = DAMEditState.RedactionLayer(name: "AI Detected")
                recipe.redactionLayers.append(aiLayer)
                do {
                    let detected = try await DAMRedactionDetectorService.shared.detect(
                        at: asset.path, options: options)
                    let existing = recipe.redactions.filter { $0.layerID == aiLayer.id }
                    let newBoxes = detected.filter { candidate in
                        !existing.contains { DAMEditState.iou(candidate.rect, $0.rect) > 0.7 }
                    }
                    let boxes = newBoxes.map { box -> DAMEditState.RedactionBox in
                        var copy = box
                        copy.id = UUID()
                        copy.layerID = aiLayer.id
                        return copy
                    }
                    recipe.redactions.append(contentsOf: boxes)
                    try? DAMDatabase.shared.saveEdits(assetId: assetId, recipe)
                    totalBoxes += boxes.count
                    applied += 1
                } catch {
                    NSLog("[AI Redact] failed for %@: %@", asset.path, "\(error)")
                }
            }
            confirmation = "AI redacted \(applied) asset(s), added \(totalBoxes) box(es)."
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
