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
    /// Redaction boxes layered above the image — blackout or blur. Stored in
    /// the same normalized 0…1 frame the preview shows (post-rotation,
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

    /// One redaction box: a normalized rect plus its treatment.
    struct RedactionBox: Codable, Sendable, Equatable, Identifiable {
        var id: UUID = UUID()
        var rect: CropRect
        var kind: Kind

        enum Kind: String, Codable, Sendable, CaseIterable {
            /// Solid black fill — unrecoverable, for text/numbers.
            case blackout
            /// Gaussian blur — for faces/areas where context should remain.
            case blur
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
        case redactions
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
