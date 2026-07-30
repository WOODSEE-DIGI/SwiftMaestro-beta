import Foundation
import UniformTypeIdentifiers

// MARK: - MaestroDAM File Kind Guards
//
// Shared type guards used by both the thumbnail pipeline (ThumbnailService)
// and the import pipeline (DAMImportService) to keep files Apple's RAWCamera
// can't parse (Phase One IIQ, Capture One EIP) away from ImageIO/QuickLook
// entirely — those calls emit `RA30 initImage err=-50` per file.
//
// LibRaw handles these formats instead (see RAWPreviewDecoder).

enum DAMFileKind {

    /// Extensions/UTIs that Apple's RAW decoder rejects on this Mac (import
    /// AND thumbnails). Everything else RAW is fine for ImageIO property
    /// reads (NEF/ARW/CR3/DNG/CR2/RAF all extract correctly).
    static let librawOnlyExtensions: Set<String> = ["iiq", "pef"]
    static let librawOnlyUTIs: Set<String> = ["com.phaseone.raw-image", "com.pentax.raw-image"]

    /// Whether the file should bypass ImageIO/QuickLook and go straight to
    /// LibRaw (thumbnail) or skip metadata extraction (import).
    static func isLibRAWOnly(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if librawOnlyExtensions.contains(ext) { return true }
        if let uti = UTType(filenameExtension: ext), librawOnlyUTIs.contains(uti.identifier) {
            return true
        }
        return false
    }

    /// Whether the file is ANY camera RAW variant. Thumbnails for all of
    /// these go LibRaw-first: Apple's decoder fails on several variants
    /// (RA30/RA02/RA04 errors per file), while LibRaw's embedded-preview
    /// extraction is uniformly fast (~10-100ms) and spam-free.
    static func isCameraRAW(_ url: URL) -> Bool {
        guard let uti = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return uti.conforms(to: .rawImage)
    }

    /// ZIP magic bytes. Capture One `.eip` packages are typed by the system
    /// as `public.camera-raw-image` (not `com.apple.package`), so
    /// ImageIO/QL try to parse them as images and fail — checking the
    /// signature is the reliable guard, independent of any UTI declaration.
    static func isZIPPackage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let header = try? handle.read(upToCount: 4) else { return false }
        try? handle.close()
        return header.count == 4
            && header[header.startIndex] == 0x50   // 'P'
            && header[header.index(after: header.startIndex)] == 0x4B // 'K'
            && header[header.index(header.startIndex, offsetBy: 2)] == 0x03
            && header[header.index(header.startIndex, offsetBy: 3)] == 0x04
    }

    /// Standard (non-RAW) image formats — HEIC/JPEG/PNG/TIFF/GIF/WebP etc.
    /// Thumbnails for these render via ImageIO directly: uniformly fast
    /// (~5-50ms), immune to QL queue starvation, and never anywhere near
    /// LibRaw (whose parsers can crash on non-RAW bytes).
    static func isStandardImage(_ url: URL) -> Bool {
        guard let uti = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return uti.conforms(to: .image) && !uti.conforms(to: .rawImage)
    }

    /// Whether the import pass should skip ImageIO metadata extraction for
    /// this file: LibRaw-only RAWs (RA30 errors on property reads) and
    /// ZIP-packaged RAWs (not parseable as images at all).
    static func shouldSkipImageIO(_ url: URL) -> Bool {
        isLibRAWOnly(url) || isZIPPackage(url)
    }
}
