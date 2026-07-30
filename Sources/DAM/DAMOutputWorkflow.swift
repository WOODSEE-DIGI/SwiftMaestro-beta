import AppKit
import SwiftUI

// MARK: - MaestroDAM Output & Edit Workspaces
//
// Output — export panel: preset list (JPEG render / copy originals),
//          settings, destination picker, progress, reveal.
// Edit   — batch operations on the current selection: rating and user
//          keywords (both audited in damAudit).
//
// The actual export engine (`DAMExportService`) is nonisolated so heavy RAW
// decodes never touch the main thread; progress is reported via a @Sendable
// callback that hops back through `DAMViewModel`.

// MARK: - Export engine

enum DAMExportService {

    enum ExportPreset: Sendable {
        /// maxPixel == 0 → original size (JPEG originals are copied verbatim).
        case jpeg(maxPixel: Int, quality: Double)
        case copyOriginals
    }

    struct ExportResult: Sendable {
        var exported: [URL] = []
        /// (filename, reason) — e.g. offline files or unsupported EIP packages.
        var skipped: [(String, String)] = []
        /// (filename, error description)
        var failed: [(String, String)] = []
    }

    enum ExportError: Error, Sendable {
        case renderFailed
        case encodeFailed
    }

    private struct ExportSkip: Error {
        let reason: String
    }

    /// Export every asset, serially (full-res RAW decodes spike ~1 GB — do
    /// NOT parallelize). Progress: (completed, total, currentFilename).
    nonisolated static func export(
        assets: [DAMAsset],
        preset: ExportPreset,
        destination: URL,
        progress: @Sendable (Int, Int, String) -> Void
    ) async -> ExportResult {
        var result = ExportResult()
        try? FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)

        for (index, asset) in assets.enumerated() {
            progress(index, assets.count, asset.filename)
            do {
                if let url = try exportOne(asset, preset: preset, to: destination) {
                    result.exported.append(url)
                }
            } catch let skip as ExportSkip {
                result.skipped.append((asset.filename, skip.reason))
            } catch {
                result.failed.append((asset.filename, error.localizedDescription))
            }
        }
        progress(assets.count, assets.count, "")
        return result
    }

    private nonisolated static func exportOne(
        _ asset: DAMAsset,
        preset: ExportPreset,
        to destination: URL
    ) throws -> URL? {
        let source = URL(fileURLWithPath: asset.path)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ExportSkip(reason: "File offline or missing")
        }

        switch preset {
        case .copyOriginals:
            let target = uniqueURL(destination.appendingPathComponent(asset.filename))
            try FileManager.default.copyItem(at: source, to: target)
            return target

        case .jpeg(let maxPixel, let quality):
            if DAMFileKind.isZIPPackage(source) {
                throw ExportSkip(reason: "EIP package — JPEG export not supported yet")
            }
            let base = (asset.filename as NSString).deletingPathExtension + ".jpg"
            let target = uniqueURL(destination.appendingPathComponent(base))

            if DAMFileKind.isCameraRAW(source) {
                // LibRaw decode → JPEG. The shim's embedded-preview rule means
                // large targets always trigger a real full-quality decode.
                let ceiling = maxPixel > 0 ? maxPixel : 12000
                let data = try RAWPreviewDecoder.jpegPreviewForRAW(
                    atPath: source.path, maxPixelSize: CGFloat(ceiling))
                try data.write(to: target, options: .atomic)
                return target
            }

            let ext = source.pathExtension.lowercased()
            if maxPixel == 0, ext == "jpg" || ext == "jpeg" {
                // Already a full-size JPEG — copy through untouched.
                try FileManager.default.copyItem(at: source, to: target)
                return target
            }

            let data = try renderJPEG(source: source, maxPixel: maxPixel, quality: quality)
            try data.write(to: target, options: .atomic)
            return target
        }
    }

    /// ImageIO render for non-RAW sources (JPEG/PNG/TIFF/HEIC…), optionally
    /// downscaled to `maxPixel` on the longest edge.
    private nonisolated static func renderJPEG(
        source: URL, maxPixel: Int, quality: Double
    ) throws -> Data {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ExportError.renderFailed
        }
        let cgImage: CGImage?
        if maxPixel > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }
        guard let cgImage else { throw ExportError.renderFailed }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(
            using: .jpeg, properties: [.compressionFactor: NSNumber(value: quality)]
        ) else {
            throw ExportError.encodeFailed
        }
        return data
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

struct OutputWorkspaceView: View {
    var viewModel: DAMViewModel

    private enum Preset: String, CaseIterable, Identifiable {
        case jpeg = "Export as JPEG"
        case copy = "Copy Originals"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .jpeg: return "photo"
            case .copy: return "doc.on.doc"
            }
        }

        var summary: String {
            switch self {
            case .jpeg:
                return "Render the selection to JPEG — RAW files decode at full "
                     + "quality via LibRaw, standard images via ImageIO."
            case .copy:
                return "Copy the original files to the destination folder, unchanged."
            }
        }
    }

    @State private var preset: Preset = .jpeg
    @State private var maxDimension = 2048   // 0 = original size
    @State private var quality: Double = 0.85
    @State private var destinationPath =
        ("~/Pictures/MaestroDAM Exports" as NSString).expandingTildeInPath

    /// Selection restricted to the loaded page (for the filmstrip preview).
    private var selectedInPage: [DAMAsset] {
        viewModel.assets.filter { viewModel.selection.contains($0.id ?? -1) }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: export presets
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Export")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                List(selection: $preset) {
                    ForEach(Preset.allCases) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .tag(item)
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 170, idealWidth: 200, maxWidth: 240)

            Divider()

            // Center: summary / progress + selection strip
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: preset.icon)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(preset.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text("\(viewModel.selection.count) item(s) selected")
                    .font(.headline)

                if viewModel.isExporting {
                    ProgressView(
                        value: Double(viewModel.exportProgressDone),
                        total: Double(max(1, viewModel.exportProgressTotal))
                    )
                    .frame(width: 320)
                    Text(viewModel.exportCurrentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let result = viewModel.lastExportResult {
                    resultSummary(result)
                } else {
                    Text("Select assets in Home or Filmstrip first — "
                         + "everything selected is exported.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                Divider()
                FilmstripBar(viewModel: viewModel, assets: selectedInPage)
                    .frame(height: 140)
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Right: settings
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Output Settings")
                        .font(.headline)

                    if preset == .jpeg {
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
                        VStack(alignment: .leading, spacing: 6) {
                            Text("JPEG Quality: \(Int(quality * 100))%")
                                .font(.subheadline.weight(.semibold))
                            Slider(value: $quality, in: 0.5...1.0)
                            Text("RAW decodes always export at maximum quality.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

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
                        startExport()
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
    }

    @ViewBuilder
    private func resultSummary(_ result: DAMExportService.ExportResult) -> some View {
        VStack(spacing: 6) {
            Text("Exported \(result.exported.count) file(s)")
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
    private func startExport() {
        let exportPreset: DAMExportService.ExportPreset = preset == .jpeg
            ? .jpeg(maxPixel: maxDimension, quality: quality)
            : .copyOriginals
        let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
        Task {
            await viewModel.exportSelection(preset: exportPreset, destination: destination)
        }
    }
}

// MARK: - Edit workspace

struct EditWorkspaceView: View {
    var viewModel: DAMViewModel

    private enum BatchTask: String, CaseIterable, Identifiable {
        case rating = "Batch Rating"
        case keywords = "Batch Keywords"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .rating: return "star"
            case .keywords: return "tag"
            }
        }
    }

    @State private var task: BatchTask = .rating
    @State private var ratingDraft = 5
    @State private var keywordDraft = ""
    @State private var keywordMode: DAMViewModel.KeywordApplyMode = .add
    @State private var confirmation = ""

    private var selectedInPage: [DAMAsset] {
        viewModel.assets.filter { viewModel.selection.contains($0.id ?? -1) }
    }

    var body: some View {
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
                            "Select assets in Home, Filmstrip, or Metadata "
                            + "(⌘-click for multiple), then apply a batch operation here.")
                    )
                } else {
                    switch task {
                    case .rating:
                        ratingControls
                    case .keywords:
                        keywordControls
                    }
                }

                if !confirmation.isEmpty {
                    Text(confirmation)
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Spacer()
                Divider()
                FilmstripBar(viewModel: viewModel, assets: selectedInPage)
                    .frame(height: 140)
            }
            .frame(maxWidth: .infinity)
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
