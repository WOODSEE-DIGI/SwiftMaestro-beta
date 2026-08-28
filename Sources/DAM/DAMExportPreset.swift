import Foundation

// MARK: - Export Presets
//
// Named, saved export configurations for MaestroDAM's Output workspace.
// A preset bundles everything an export needs: format, sizing, quality,
// metadata policy, watermark, and destination. Built-ins cover the common
// cases; user presets persist as JSON next to the catalog database (the DAM
// folder inside Application Support — already a default-authorized folder).

/// One saved export configuration.
struct DAMExportPreset: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var format: Format = .jpeg
    /// 0 = original size.
    var maxDimension: Int = 2048
    /// Lossy quality for JPEG / HEIC (0.5…1.0). Ignored by PNG/TIFF.
    var quality: Double = 0.85
    /// How much source metadata travels into re-rendered exports.
    var metadata: MetadataPolicy = .some
    var watermark: WatermarkSettings = .init()
    var destinationPath: String = DAMExportPreset.defaultDestination

    static let defaultDestination =
        ("~/Pictures/MaestroDAM Exports" as NSString).expandingTildeInPath

    // MARK: Format

    enum Format: String, Codable, CaseIterable, Identifiable, Sendable {
        case jpeg, png, heic, tiff, copyOriginals

        var id: String { rawValue }

        var title: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            case .heic: return "HEIC"
            case .tiff: return "TIFF"
            case .copyOriginals: return "Copy Originals"
            }
        }

        /// True when the export re-renders pixels (everything except a
        /// verbatim copy). Watermark / metadata policy / sizing only apply
        /// to re-renders — a verbatim copy keeps the original file, metadata
        /// and all.
        var reRenders: Bool { self != .copyOriginals }

        /// Lossy quality slider applies to JPEG and HEIC only.
        var supportsQuality: Bool { self == .jpeg || self == .heic }

        /// Extension for rendered exports (unused by copyOriginals).
        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .heic: return "heic"
            case .tiff: return "tiff"
            case .copyOriginals: return ""
            }
        }
    }

    // MARK: Metadata policy

    /// How much of the source file's metadata dictionary is re-attached to a
    /// re-rendered export. (Rendering rasterizes pixels — metadata does not
    /// survive the pipeline unless explicitly re-attached at encode time.)
    enum MetadataPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Strip everything — smallest, most private files.
        case none
        /// Keep camera/lens/exposure + orientation; drop GPS, IPTC owner
        /// fields, maker notes, and serial numbers.
        case some
        /// Re-attach the source properties dictionary verbatim.
        case all

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "None"
            case .some: return "Some"
            case .all: return "All"
            }
        }
    }

    // MARK: Watermark

    struct WatermarkSettings: Codable, Equatable, Sendable {
        var enabled = false
        var text = ""
        var position: Position = .bottomRight
        var opacity: Double = 0.6
        /// Font size as a fraction of the image's longest edge (0.01…0.15).
        var relativeSize: Double = 0.03

        enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
            case topLeft, topRight, bottomLeft, bottomRight, center

            var id: String { rawValue }

            var title: String {
                switch self {
                case .topLeft: return "Top Left"
                case .topRight: return "Top Right"
                case .bottomLeft: return "Bottom Left"
                case .bottomRight: return "Bottom Right"
                case .center: return "Center"
                }
            }

            /// Bottom-left-origin point for the text, given canvas + text size.
            func point(canvas: CGSize, textSize: CGSize, margin: CGFloat) -> CGPoint {
                switch self {
                case .topLeft:
                    return CGPoint(x: margin, y: canvas.height - margin - textSize.height)
                case .topRight:
                    return CGPoint(x: canvas.width - margin - textSize.width,
                                   y: canvas.height - margin - textSize.height)
                case .bottomLeft:
                    return CGPoint(x: margin, y: margin)
                case .bottomRight:
                    return CGPoint(x: canvas.width - margin - textSize.width, y: margin)
                case .center:
                    return CGPoint(x: (canvas.width - textSize.width) / 2,
                                   y: (canvas.height - textSize.height) / 2)
                }
            }
        }
    }
}

// MARK: - Built-in presets

extension DAMExportPreset {
    /// Built-ins are immutable starting points — "Save as New…" forks one
    /// into a user preset. Stable UUIDs keep them identifiable across
    /// launches (literals are valid by construction).
    static let builtIns: [DAMExportPreset] = [
        DAMExportPreset(
            id: UUID(uuidString: "E5000000-0000-0000-0000-000000000001")!,
            name: "Export as JPEG",
            format: .jpeg, maxDimension: 2048, quality: 0.85, metadata: .some),
        DAMExportPreset(
            id: UUID(uuidString: "E5000000-0000-0000-0000-000000000002")!,
            name: "Copy Originals",
            format: .copyOriginals, maxDimension: 0, metadata: .all),
        DAMExportPreset(
            id: UUID(uuidString: "E5000000-0000-0000-0000-000000000003")!,
            name: "Web JPEG — No Metadata",
            format: .jpeg, maxDimension: 2048, quality: 0.8, metadata: .none),
        DAMExportPreset(
            id: UUID(uuidString: "E5000000-0000-0000-0000-000000000004")!,
            name: "Archive TIFF",
            format: .tiff, maxDimension: 0, quality: 1.0, metadata: .all),
    ]

    static func isBuiltIn(_ id: UUID) -> Bool {
        builtIns.contains { $0.id == id }
    }
}

// MARK: - Preset store

/// JSON-file persistence for user-created export presets. Errors surface as
/// throws on save and as an empty list on load (a corrupt file is preserved
/// aside as `.bad` before any overwrite — backup-before-destructive).
struct DAMExportPresetStore: Sendable {

    let fileURL: URL

    init(fileURL: URL = DAMExportPresetStore.defaultURL) {
        self.fileURL = fileURL
    }

    static let defaultURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro/DAM", isDirectory: true)
            .appendingPathComponent("export-presets.json")
    }()

    func load() -> [DAMExportPreset] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let presets = try? JSONDecoder().decode([DAMExportPreset].self, from: data)
        else {
            // Preserve the unreadable file rather than silently overwriting it.
            let aside = fileURL.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            return []
        }
        return presets
    }

    func save(_ presets: [DAMExportPreset]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(presets)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Convenience: add a new preset (or replace one with the same id).
    func upsert(_ preset: DAMExportPreset) throws {
        var all = load()
        if let index = all.firstIndex(where: { $0.id == preset.id }) {
            all[index] = preset
        } else {
            all.append(preset)
        }
        try save(all)
    }

    func delete(id: UUID) throws {
        try save(load().filter { $0.id != id })
    }
}
