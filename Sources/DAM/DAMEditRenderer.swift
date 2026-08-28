import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UniformTypeIdentifiers

// MARK: - Non-destructive Edit Renderer
//
// Renders a DAM asset with a DAMEditState recipe via CoreImage:
//   source load (RAW via LibRaw preview decode, else direct) →
//   geometry (rotate quarter-turns + straighten angle + flip + crop) →
//   tone (exposure, highlights/shadows, contrast) →
//   color (vibrance, saturation, temperature/tint) →
//   effects (sharpen, noise reduction, B&W).
//
// Every call is a fresh pure computation — the recipe is the only state.

enum DAMEditRenderer {

    enum RenderError: Error {
        case cannotLoad(String)
        case noOutput
    }

    /// Render the asset with its edit recipe. `maxPixelSize` caps the longest
    /// edge (preview = fast path; pass 0 for full resolution exports).
    static func render(asset: DAMAsset, edit: DAMEditState, maxPixelSize: Int = 2000) throws -> NSImage {
        var image = try loadCIImage(for: asset, maxPixelSize: maxPixelSize)
        image = applyGeometry(edit, to: image)
        image = applyTone(edit, to: image)
        image = applyColor(edit, to: image)
        image = applyEffects(edit, to: image)
        image = applyRedactions(edit, to: image)
        return try nsImage(from: image)
    }

    // MARK: - Source

    /// Load the asset as a CIImage. RAW files decode via the vendored LibRaw
    /// path (same engine as darktable/digiKam); everything else reads
    /// directly. `maxPixelSize` bounds the RAW preview decode for interactivity.
    private static func loadCIImage(for asset: DAMAsset, maxPixelSize: Int) throws -> CIImage {
        let url = URL(fileURLWithPath: asset.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RenderError.cannotLoad(asset.filename)
        }

        if DAMFileKind.isCameraRAW(url) {
            let data = try RAWPreviewDecoder.jpegPreviewForRAW(
                atPath: url.path,
                maxPixelSize: CGFloat(maxPixelSize > 0 ? maxPixelSize : 12000))
            guard let image = CIImage(data: data) else {
                throw RenderError.cannotLoad(asset.filename)
            }
            return image
        }

        guard let image = CIImage(contentsOf: url) else {
            throw RenderError.cannotLoad(asset.filename)
        }
        return image
    }

    // MARK: - Chain stages

    private static func applyGeometry(_ edit: DAMEditState, to image: CIImage) -> CIImage {
        var out = image
        let extent = out.extent

        if edit.flipHorizontal {
            out = out.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -extent.width, y: 0))
        }

        let quarterDegrees = Double(edit.rotateQuarterTurns % 4) * 90
        let totalDegrees = quarterDegrees + edit.straightenDegrees
        if totalDegrees != 0 {
            let radians = totalDegrees * .pi / 180
            out = out.transformed(by: CGAffineTransform(rotationAngle: radians))
        }

        if let crop = edit.crop {
            let e = out.extent
            let rect = CGRect(
                x: e.minX + crop.x * e.width,
                // Recipe coords are top-left-origin (the displayed frame);
                // CIImage is bottom-left-origin — flip y.
                y: e.minY + (1 - crop.y - crop.height) * e.height,
                width: crop.width * e.width,
                height: crop.height * e.height
            )
            .integral
            .intersection(e)
            if !rect.isNull, !rect.isEmpty {
                out = out.cropped(to: rect)
            }
        }

        return out
    }

    // MARK: - Redaction stage

    /// Redaction boxes render LAST (after effects), so both the preview and
    /// exports bake them in. Recipe coords are normalized top-left-origin
    /// (the displayed frame, post-crop); CIImage is bottom-left-origin —
    /// flip y when mapping. Blackout = solid fill; blur = gaussian with the
    /// region's own edge pixels clamped outward first (so the blur smears
    /// with itself, not with the surroundings or transparency).
    private static func applyRedactions(_ edit: DAMEditState, to image: CIImage) -> CIImage {
        guard !edit.redactions.isEmpty else { return image }
        var out = image
        let extent = out.extent
        for box in edit.redactions {
            let rect = CGRect(
                x: extent.minX + box.rect.x * extent.width,
                y: extent.minY + (1 - box.rect.y - box.rect.height) * extent.height,
                width: box.rect.width * extent.width,
                height: box.rect.height * extent.height
            )
            .integral
            .intersection(extent)
            if rect.isNull || rect.isEmpty { continue }
            switch box.kind {
            case .blackout:
                out = CIImage(color: .black).cropped(to: rect).composited(over: out)
            case .blur:
                let radius = max(rect.width, rect.height) * 0.12
                let blurred = out
                    .clamped(to: rect)
                    .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                    .cropped(to: rect)
                out = blurred.composited(over: out)
            }
        }
        return out
    }

    /// Instantiate a CoreImage filter by name, set inputImage + any params,
    /// and return its output (falling back to the input when anything fails).
    /// The string-name API is used because it's stable across SDK versions —
    /// the CIFilterBuiltins signatures vary between releases.
    private static func filter(
        _ name: String,
        input: CIImage,
        _ params: [String: Any] = [:]
    ) -> CIImage {
        guard let f = CIFilter(name: name) else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        for (key, value) in params { f.setValue(value, forKey: key) }
        return f.outputImage ?? input
    }

    private static func applyTone(_ edit: DAMEditState, to image: CIImage) -> CIImage {
        var out = image
        if edit.exposureEV != 0 {
            out = filter("CIExposureAdjust", input: out, ["inputEV": edit.exposureEV])
        }
        if edit.highlights != 0 || edit.shadows != 0 {
            out = filter("CIHighlightShadowAdjust", input: out, [
                "inputHighlightAmount": 1 + edit.highlights,   // 1 = unchanged
                "inputShadowAmount": edit.shadows,             // 0 = unchanged
            ])
        }
        if edit.contrast != 1.0 {
            out = filter("CIColorControls", input: out, [
                "inputSaturation": 1.0, "inputBrightness": 0.0, "inputContrast": edit.contrast])
        }
        return out
    }

    private static func applyColor(_ edit: DAMEditState, to image: CIImage) -> CIImage {
        var out = image
        if edit.blackAndWhite {
            return filter("CIPhotoEffectMono", input: out)
        }
        if edit.temperature != 6500 || edit.tint != 0 {
            out = filter("CITemperatureAndTint", input: out, [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(edit.temperature), y: CGFloat(edit.tint)),
            ])
        }
        if edit.vibrance != 0 {
            out = filter("CIVibrance", input: out, ["inputAmount": edit.vibrance])
        }
        if edit.saturation != 1.0 {
            out = filter("CIColorControls", input: out, [
                "inputSaturation": edit.saturation, "inputBrightness": 0.0, "inputContrast": 1.0])
        }
        return out
    }

    private static func applyEffects(_ edit: DAMEditState, to image: CIImage) -> CIImage {
        var out = image
        if edit.noiseReduction > 0 {
            out = filter("CINoiseReduction", input: out, [
                "inputNoiseLevel": 0.02 * edit.noiseReduction, "inputSharpness": 0.4])
        }
        if edit.sharpen > 0 {
            out = filter("CISharpenLuminance", input: out, ["inputSharpness": edit.sharpen])
        }
        return out
    }

    // MARK: - Output

    private static func nsImage(from ciImage: CIImage) throws -> NSImage {
        let context = ciContext()
        var rect = ciImage.extent
        rect.origin = .zero
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw RenderError.noOutput
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Shared CIContext (GPU-backed) — creating one per render is the
    /// expensive part, so keep a single one.
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func ciContext() -> CIContext { sharedContext }

    // MARK: - Export pipeline (formats / metadata / watermark)

    /// Render to a CGImage (export path) — the same chain as render(), ending
    /// at the bitmap so the caller can watermark and encode in any format.
    static func renderCGImage(asset: DAMAsset, edit: DAMEditState, maxPixelSize: Int) throws -> CGImage {
        var image = try loadCIImage(for: asset, maxPixelSize: maxPixelSize)
        image = applyGeometry(edit, to: image)
        image = applyTone(edit, to: image)
        image = applyColor(edit, to: image)
        image = applyEffects(edit, to: image)
        image = applyRedactions(edit, to: image)
        guard let cg = ciContext().createCGImage(image, from: image.extent) else {
            throw RenderError.noOutput
        }
        return cg
    }

    /// Encode a CGImage to the preset's format, re-attaching source metadata
    /// according to the policy (rendering rasterizes pixels — metadata only
    /// survives if explicitly re-attached here at encode time).
    static func encode(
        _ image: CGImage,
        format: DAMExportPreset.Format,
        quality: Double,
        sourceURL: URL,
        metadataPolicy: DAMExportPreset.MetadataPolicy
    ) throws -> Data {
        let type: UTType = switch format {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .copyOriginals: .jpeg   // never encoded — verbatim path only
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)
        else { throw RenderError.noOutput }

        var options: [CFString: Any] = [:]
        if format.supportsQuality {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // Metadata travels via the image properties at add-image time.
        let sourceProps = CGImageSourceCreateWithURL(sourceURL as CFURL, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] }
        let filtered = filteredMetadata(sourceProps, policy: metadataPolicy)
        CGImageDestinationAddImage(destination, image, filtered as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else {
            throw RenderError.noOutput
        }
        return data as Data
    }

    /// Filter a source file's ImageIO properties dictionary by policy.
    /// Pure + testable. Returns nil for `.none` (strip everything).
    ///
    /// `.some` keeps camera/lens/exposure + orientation but drops everything
    /// identifying or locating the owner: GPS, IPTC (creator/contact fields),
    /// maker notes, and camera/lens serial numbers.
    static func filteredMetadata(
        _ source: [String: Any]?,
        policy: DAMExportPreset.MetadataPolicy
    ) -> [String: Any]? {
        guard let source, policy != .none else { return nil }
        if policy == .all { return source }

        var out: [String: Any] = [:]
        let tiffKey = kCGImagePropertyTIFFDictionary as String
        let exifKey = kCGImagePropertyExifDictionary as String
        let auxKey = kCGImagePropertyExifAuxDictionary as String

        if let tiff = source[tiffKey] as? [String: Any] {
            var kept: [String: Any] = [:]
            for key in [kCGImagePropertyTIFFOrientation as String,
                        kCGImagePropertyTIFFMake as String,
                        kCGImagePropertyTIFFModel as String,
                        kCGImagePropertyTIFFDateTime as String] {
                if let value = tiff[key] { kept[key] = value }
            }
            if !kept.isEmpty { out[tiffKey] = kept }
        }
        if let exif = source[exifKey] as? [String: Any] {
            let dropped: Set<String> = [
                kCGImagePropertyExifMakerNote as String,
                kCGImagePropertyExifUserComment as String,
            ]
            let kept = exif.filter { !dropped.contains($0.key) }
            if !kept.isEmpty { out[exifKey] = kept }
        }
        if let aux = source[auxKey] as? [String: Any] {
            let dropped: Set<String> = [
                kCGImagePropertyExifAuxSerialNumber as String,
                kCGImagePropertyExifAuxLensSerialNumber as String,
                kCGImagePropertyExifAuxOwnerName as String,
            ]
            let kept = aux.filter { !dropped.contains($0.key) }
            if !kept.isEmpty { out[auxKey] = kept }
        }
        // GPS / IPTC / PNG / CIFF / 8BIM dictionaries: intentionally dropped.
        return out.isEmpty ? nil : out
    }

    /// Draw a text watermark onto a rendered image. Returns the input
    /// unchanged when disabled/empty. Drawn in a bitmap context the size of
    /// the image; font scales with the longest edge; bottom-left origin.
    static func applyWatermark(
        _ image: CGImage,
        settings: DAMExportPreset.WatermarkSettings
    ) -> CGImage {
        guard settings.enabled, !settings.text.isEmpty else { return image }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let canvas = CGSize(width: width, height: height)
        let fontSize = max(
            10.0, settings.relativeSize * Double(max(width, height)))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(settings.opacity),
            // Subtle dark shadow keeps the text legible on bright subjects.
            .shadow: { let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(min(1, settings.opacity + 0.2))
                shadow.shadowBlurRadius = fontSize * 0.15
                shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.06)
                return shadow }(),
        ]
        let attributed = NSAttributedString(string: settings.text, attributes: attributes)
        let textSize = attributed.size()
        let origin = settings.position.point(
            canvas: canvas, textSize: textSize, margin: fontSize)

        // Bridge into AppKit text drawing over the bitmap context.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage() ?? image
    }
}

// MARK: - CGImage sizing

extension CGImage {
    /// Downscale so the longest edge is at most `maxPixel` (no-op when the
    /// image already fits). High-quality sRGB bitmap redraw.
    func downscaled(toMaxPixel maxPixel: Int) -> CGImage {
        let longest = max(width, height)
        guard maxPixel > 0, longest > maxPixel else { return self }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        let targetWidth = max(1, Int((CGFloat(width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(height) * scale).rounded()))
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: targetWidth, height: targetHeight,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: srgb,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return self }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? self
    }
}
