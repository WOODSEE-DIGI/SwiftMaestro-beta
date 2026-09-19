import CoreGraphics
import Foundation

// MARK: - Non-destructive Edit Recipe
//
// One per DAM asset, stored as JSON in the `assetEdit` table (v8 migration).
// The original file is NEVER touched — edits live here and are re-applied by
// DAMEditRenderer whenever a preview or export is produced. This is the
// Lightroom/darktable model: the recipe is the state; rendering is pure.

/// The complete non-destructive edit recipe for one asset.
struct DAMEditState: Codable, Sendable, Equatable {

    // MARK: Geometry
    /// Quarter-turns clockwise: 0, 1, 2, 3 (90° steps).
    var rotateQuarterTurns: Int = 0
    /// Fine straighten angle in degrees (-45…+45).
    var straightenDegrees: Double = 0
    /// Horizontal flip.
    var flipHorizontal: Bool = false
    /// Normalized crop rect (0…1 in the ROTATED/STRAIGHTENED frame — the same
    /// space the preview shows: what you see is what you crop). nil = full frame.
    var crop: CropRect? = nil

    // MARK: Light
    /// Exposure in stops (-3…+3).
    var exposureEV: Double = 0
    /// Contrast multiplier (1.0 = none).
    var contrast: Double = 1.0
    /// Highlights recovery (-1…+1).
    var highlights: Double = 0
    /// Shadows lift (-1…+1).
    var shadows: Double = 0

    // MARK: Color
    /// Saturation multiplier (1.0 = none).
    var saturation: Double = 1.0
    /// Vibrance (-1…+1).
    var vibrance: Double = 0
    /// White-balance temperature (Kelvin-ish CI scale; 6500 = unchanged).
    var temperature: Double = 6500
    /// White-balance tint (-150…+150; 0 = unchanged).
    var tint: Double = 0

    // MARK: Effects
    /// Sharpening intensity (0…1).
    var sharpen: Double = 0
    /// Noise reduction (0…1).
    var noiseReduction: Double = 0
    /// Black & white conversion.
    var blackAndWhite: Bool = false

    // MARK: Redaction
    /// Named redaction layers. Each layer can be toggled independently, so a
    /// single asset can carry multiple redaction sets (e.g. "AI PII", "Manual
    /// Review", "Public Safe") and the user can show/hide them for review or
    /// screen recording without touching the original file.
    var redactionLayers: [RedactionLayer] = []
    /// Redaction boxes layered above the image — blackout, blur, or pixelate.
    /// Stored in the same normalized 0…1 frame the preview shows (post-rotation,
    /// post-crop: what you see is what you redact), rendered LAST in the
    /// pipeline (after effects) so exports bake them in. The original file
    /// is never touched.
    var redactions: [RedactionBox] = []

    /// Normalized crop rect in un-rotated source coordinates.
    struct CropRect: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    /// A named redaction layer. Boxes belong to a layer; only visible layers
    /// are rendered. The original file is never modified.
    struct RedactionLayer: Codable, Sendable, Equatable, Identifiable {
        var id: UUID = UUID()
        var name: String = "Redactions"
        var isVisible: Bool = true
    }

    /// One redaction box: a normalized rect plus its treatment.
    struct RedactionBox: Codable, Sendable, Equatable, Identifiable {
        var id: UUID = UUID()
        var rect: CropRect
        var kind: Kind
        /// Per-box intensity for blur/pixelate (0…1). nil means "use default".
        /// Blackout ignores this. Optional for backward compatibility with
        /// recipes saved before the strength field existed.
        var strength: Double? = nil
        /// Which layer this box belongs to. nil maps to the default layer on
        /// load for backward compatibility.
        var layerID: UUID? = nil

        enum Kind: String, Codable, Sendable, CaseIterable {
            /// Solid black fill — unrecoverable, for text/numbers.
            case blackout
            /// Gaussian blur — for faces/areas where context should remain.
            case blur
            /// Pixelate / mosaic — readable context, no fine detail.
            case pixelate

            var displayName: String {
                switch self {
                case .blackout: return String(localized: "Blackout")
                case .blur: return String(localized: "Blur")
                case .pixelate: return String(localized: "Pixelate")
                }
            }

            var systemImage: String {
                switch self {
                case .blackout: return "square.fill"
                case .blur: return "aqi.medium"
                case .pixelate: return "grid"
                }
            }

            /// Whether this kind supports a per-box strength slider.
            var hasStrength: Bool {
                switch self {
                case .blackout: return false
                case .blur, .pixelate: return true
                }
            }
        }
    }

    /// True when no edit differs from the defaults (no render needed).
    var isIdentity: Bool { self == DAMEditState() }

    // MARK: - Codable (backward-compatible)
    //
    // Custom decoding keeps OLD recipes loadable: fields added after a
    // recipe was saved (e.g. redactions) fall back to their defaults instead
    // of failing the whole decode (which used to silently reset the recipe
    // to identity via fromJSON's catch-all).

    private enum CodingKeys: String, CodingKey {
        case rotateQuarterTurns, straightenDegrees, flipHorizontal, crop
        case exposureEV, contrast, highlights, shadows
        case saturation, vibrance, temperature, tint
        case sharpen, noiseReduction, blackAndWhite
        case redactions, redactionLayers
    }

    /// All-default recipe (identity). Explicit because the custom Codable
    /// init below suppresses the synthesized memberwise initializer.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rotateQuarterTurns = try c.decodeIfPresent(Int.self, forKey: .rotateQuarterTurns) ?? 0
        straightenDegrees = try c.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
        exposureEV = try c.decodeIfPresent(Double.self, forKey: .exposureEV) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1.0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1.0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        sharpen = try c.decodeIfPresent(Double.self, forKey: .sharpen) ?? 0
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        blackAndWhite = try c.decodeIfPresent(Bool.self, forKey: .blackAndWhite) ?? false
        redactions = try c.decodeIfPresent([RedactionBox].self, forKey: .redactions) ?? []
        redactionLayers = try c.decodeIfPresent([RedactionLayer].self, forKey: .redactionLayers) ?? []
        migrateRedactionLayersIfNeeded()
    }

    /// Backward-compat migration: recipes saved before layers existed get a
    /// single default layer and all existing boxes are assigned to it.
    private mutating func migrateRedactionLayersIfNeeded() {
        if redactionLayers.isEmpty {
            if redactions.isEmpty {
                // Fresh recipe — nothing to migrate.
                return
            }
            let defaultLayer = RedactionLayer(name: "Redactions")
            redactionLayers = [defaultLayer]
            for index in redactions.indices {
                redactions[index].layerID = defaultLayer.id
            }
        } else {
            // Any box without a layer ID inherits the first (default) layer.
            let defaultLayerID = redactionLayers.first?.id
            for index in redactions.indices where redactions[index].layerID == nil {
                redactions[index].layerID = defaultLayerID
            }
        }
    }

    /// Intersection-over-union of two normalized rects (0…1). Used to avoid
    /// adding duplicate redaction boxes when AI detection is run repeatedly.
    static func iou(_ a: CropRect, _ b: CropRect) -> Double {
        let ax0 = a.x, ay0 = a.y, ax1 = a.x + a.width, ay1 = a.y + a.height
        let bx0 = b.x, by0 = b.y, bx1 = b.x + b.width, by1 = b.y + b.height
        let ix0 = max(ax0, bx0), iy0 = max(ay0, by0)
        let ix1 = min(ax1, bx1), iy1 = min(ay1, by1)
        guard ix1 > ix0, iy1 > iy0 else { return 0 }
        let intersection = (ix1 - ix0) * (iy1 - iy0)
        let areaA = a.width * a.height
        let areaB = b.width * b.height
        let union = areaA + areaB - intersection
        guard union > 0 else { return 0 }
        return intersection / union
    }

    /// Returns the boxes whose layer is currently visible. Used by the
    /// renderer and overlays so hidden layers don't draw.
    func visibleRedactions() -> [RedactionBox] {
        let visibleLayerIDs = Set(redactionLayers.filter(\.isVisible).map(\.id))
        return redactions.filter { box in
            guard let layerID = box.layerID else { return true }
            return visibleLayerIDs.contains(layerID)
        }
    }

    /// Adds a new layer and returns its ID.
    @discardableResult
    mutating func addRedactionLayer(named name: String = "New Layer") -> UUID {
        let layer = RedactionLayer(name: name)
        redactionLayers.append(layer)
        return layer.id
    }

    /// Removes a layer and all boxes that belong to it.
    mutating func removeRedactionLayer(id: UUID) {
        redactionLayers.removeAll { $0.id == id }
        redactions.removeAll { $0.layerID == id }
    }

    /// Returns a copy of the recipe safe for export: hidden layers and their
    /// boxes are stripped so they can never travel with the exported file.
    /// The original recipe (and original source file) remain untouched.
    func forExport() -> DAMEditState {
        var copy = self
        let visibleLayerIDs = Set(redactionLayers.filter(\.isVisible).map(\.id))
        copy.redactionLayers = redactionLayers.filter(\.isVisible)
        copy.redactions = redactions.filter { box in
            guard let layerID = box.layerID else { return true }
            return visibleLayerIDs.contains(layerID)
        }
        return copy
    }

    /// Returns the default layer to use when creating a new box. Creates one
    /// if the recipe has no layers yet.
    mutating func defaultRedactionLayerID() -> UUID {
        if redactionLayers.isEmpty {
            let layer = RedactionLayer(name: "Redactions")
            redactionLayers.append(layer)
            return layer.id
        }
        return redactionLayers[0].id
    }

    /// The recipe as it should be rendered while the crop tool is armed:
    /// everything EXCEPT the crop, so the user sees the full frame with the
    /// crop rect overlaid (darktable-style modal crop). When the tool is
    /// disarmed the normal render applies the crop again.
    var forCropEditing: DAMEditState {
        var copy = self
        copy.crop = nil
        return copy
    }

    /// Default value of a scalar recipe field — the single source of truth
    /// for the editor's per-slider reset buttons (read from a fresh recipe,
    /// so the reset targets can never drift from the type's defaults).
    static func defaultValue(for keyPath: KeyPath<DAMEditState, Double>) -> Double {
        DAMEditState()[keyPath: keyPath]
    }

    // MARK: - Redaction layout copy/paste
    //
    // A redaction layout travels between images via the pasteboard as a
    // marked JSON payload (distinct from a full-settings recipe payload), so
    // pasting a layout never clobbers the target's light/color/geometry.

    /// Pasteboard payload wrapper — the marker key identifies layout data.
    private struct RedactionLayoutPayload: Codable {
        var maestroRedactionLayout: [RedactionBox]
    }

    /// The redaction boxes as a pasteboard-ready JSON string.
    var redactionLayoutJSON: String {
        let payload = RedactionLayoutPayload(maestroRedactionLayout: redactions)
        return (try? JSONEncoder().encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Decode a layout payload from the pasteboard. Returns nil when the
    /// string isn't a redaction layout (so paste can no-op with feedback).
    static func redactionLayout(fromJSON json: String) -> [RedactionBox]? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(RedactionLayoutPayload.self, from: data)
        else { return nil }
        return payload.maestroRedactionLayout
    }

    // MARK: - JSON persistence

    var asJSON: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func fromJSON(_ json: String) -> DAMEditState {
        guard let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(DAMEditState.self, from: data)
        else { return DAMEditState() }
        return state
    }
}
