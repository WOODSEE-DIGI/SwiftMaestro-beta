import AppKit
import ImageIO
import XCTest
@testable import SwiftMaestro

/// Tests for the expanded export system: preset persistence, metadata
/// policy filtering, multi-format encoding, max-dimension enforcement, and
/// the watermark pass.
final class DAMExportPresetTests: XCTestCase {

    // MARK: - Preset model + store

    func testPresetRoundTrip() throws {
        var preset = DAMExportPreset(name: "Client Delivery")
        preset.format = .heic
        preset.maxDimension = 4096
        preset.quality = 0.9
        preset.metadata = .none
        preset.watermark = .init(
            enabled: true, text: "© woodsee", position: .bottomRight,
            opacity: 0.7, relativeSize: 0.04)

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(DAMExportPreset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }

    func testStoreSaveLoadDelete() throws {
        let url = URL(fileURLWithPath: "/tmp/dam-export-presets-\(UUID().uuidString).json")
        let store = DAMExportPresetStore(fileURL: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(store.load(), [])   // missing file → empty, not crash

        var preset = DAMExportPreset(name: "Proof Sheet")
        preset.format = .png
        try store.upsert(preset)
        XCTAssertEqual(store.load(), [preset])

        // Upsert with the same id replaces rather than duplicates.
        var renamed = preset
        renamed.name = "Proof Sheet v2"
        try store.upsert(renamed)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Proof Sheet v2")

        try store.delete(id: preset.id)
        XCTAssertEqual(store.load(), [])
    }

    func testStorePreservesCorruptFileAside() throws {
        let url = URL(fileURLWithPath: "/tmp/dam-export-presets-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bad"))
        }
        try Data("not json".utf8).write(to: url)
        let store = DAMExportPresetStore(fileURL: url)
        XCTAssertEqual(store.load(), [])
        // The corrupt file is moved aside, not silently destroyed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("bad").path))
    }

    func testBuiltInsAreStableAndSane() {
        // Stable ids across launches (presets reference them by id).
        XCTAssertEqual(DAMExportPreset.builtIns.map(\.name),
                       ["Export as JPEG", "Copy Originals",
                        "Web JPEG — No Metadata", "Archive TIFF"])
        XCTAssertTrue(DAMExportPreset.isBuiltIn(DAMExportPreset.builtIns[0].id))
        XCTAssertFalse(DAMExportPreset.isBuiltIn(UUID()))
        for preset in DAMExportPreset.builtIns {
            XCTAssertFalse(preset.name.isEmpty)
            if preset.format == .copyOriginals {
                XCTAssertEqual(preset.metadata, .all)   // copies keep everything
            }
        }
    }

    // MARK: - Metadata policy filtering (pure)

    func testFilteredMetadataPolicies() {
        let source: [String: Any] = [
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 16 Pro Max",
                kCGImagePropertyTIFFOrientation as String: 1,
                kCGImagePropertyTIFFSoftware as String: "SomeEditor 1.0",
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifFNumber as String: 1.9,
                kCGImagePropertyExifMakerNote as String: "opaque blob",
                kCGImagePropertyExifUserComment as String: "private note",
            ],
            kCGImagePropertyExifAuxDictionary as String: [
                kCGImagePropertyExifAuxLensModel as String: "front camera 2.69mm",
                kCGImagePropertyExifAuxSerialNumber as String: "SERIAL123",
                kCGImagePropertyExifAuxLensSerialNumber as String: "LENSSERIAL",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: -34.00386,
                kCGImagePropertyGPSLongitude as String: 151.12793,
            ],
            kCGImagePropertyIPTCDictionary as String: [
                kCGImagePropertyIPTCCreatorContactInfo as String: "contact blob",
            ],
        ]

        // None → strip everything.
        XCTAssertNil(DAMEditRenderer.filteredMetadata(source, policy: .none))
        // All → verbatim.
        XCTAssertEqual(
            DAMEditRenderer.filteredMetadata(source, policy: .all)?.count, source.count)

        // Some → camera/exposure survive; GPS/IPTC/serials/maker notes gone.
        let some = DAMEditRenderer.filteredMetadata(source, policy: .some)
        XCTAssertNotNil(some)
        let tiff = some?[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "Apple")
        XCTAssertNil(tiff?[kCGImagePropertyTIFFSoftware as String])
        let exif = some?[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNotNil(exif?[kCGImagePropertyExifFNumber as String])
        XCTAssertNil(exif?[kCGImagePropertyExifMakerNote as String])
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
        let aux = some?[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        XCTAssertNotNil(aux?[kCGImagePropertyExifAuxLensModel as String])
        XCTAssertNil(aux?[kCGImagePropertyExifAuxSerialNumber as String])
        XCTAssertNil(aux?[kCGImagePropertyExifAuxLensSerialNumber as String])
        XCTAssertNil(some?[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(some?[kCGImagePropertyIPTCDictionary as String])
    }

    // MARK: - Encoding formats

    /// 64x32 color-block CGImage for encode tests.
    private func makeTestCGImage() throws -> CGImage {
        let size = NSSize(width: 64, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSColor.blue.setFill()
        NSRect(x: 32, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw XCTSkip("could not build test CGImage")
        }
        return cg
    }

    func testEncodeAllRenderedFormats() throws {
        let cg = try makeTestCGImage()
        let sourceURL = URL(fileURLWithPath: "/tmp/dam-export-tests-source.jpg")
        for format in [DAMExportPreset.Format.jpeg, .png, .heic, .tiff] {
            let data = try DAMEditRenderer.encode(
                cg, format: format, quality: 0.85,
                sourceURL: sourceURL, metadataPolicy: .none)
            XCTAssertGreaterThan(data.count, 100, "\(format) produced no data")
            // The encoded data must decode back to an image at the same size.
            // (Width follows the fixture's backing scale — Retina hosts
            // produce 2x pixels — so assert against the source image, not
            // a magic number.)
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
                XCTFail("\(format) output is not a readable image")
                return
            }
            let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil)
            XCTAssertNotNil(decoded, "\(format) output did not decode")
            XCTAssertEqual(decoded?.width, cg.width, "\(format) changed the width")
        }
    }

    func testDownscaledEnforcesMaxDimension() throws {
        let cg = try makeTestCGImage()
        // Scale to half the longest edge (fixture pixels are backing-scale
        // dependent, so compute from the actual image).
        let half = max(cg.width, cg.height) / 2
        let halved = cg.downscaled(toMaxPixel: half)
        XCTAssertEqual(max(halved.width, halved.height), half)
        XCTAssertEqual(halved.height, halved.width / 2)   // 2:1 fixture
        // Already-small images pass through unchanged.
        let same = cg.downscaled(toMaxPixel: max(cg.width, cg.height) * 2)
        XCTAssertEqual(same.width, cg.width)
        // 0 = original size — no-op.
        let noop = cg.downscaled(toMaxPixel: 0)
        XCTAssertEqual(noop.width, cg.width)
    }

    // MARK: - Watermark

    func testWatermarkNoOpWhenDisabledOrEmpty() throws {
        let cg = try makeTestCGImage()
        var settings = DAMExportPreset.WatermarkSettings()   // enabled = false
        settings.text = "© woodsee"
        XCTAssertTrue(cg.downscaled(toMaxPixel: 0) === cg)   // sanity
        let disabled = DAMEditRenderer.applyWatermark(cg, settings: settings)
        XCTAssertEqual(disabled.width, cg.width)
        settings.enabled = true
        settings.text = ""   // empty text → no-op
        let empty = DAMEditRenderer.applyWatermark(cg, settings: settings)
        XCTAssertEqual(empty.width, cg.width)
    }

    func testWatermarkDrawsAndKeepsSize() throws {
        let cg = try makeTestCGImage()
        let settings = DAMExportPreset.WatermarkSettings(
            enabled: true, text: "© woodsee", position: .bottomRight,
            opacity: 0.8, relativeSize: 0.1)
        let marked = DAMEditRenderer.applyWatermark(cg, settings: settings)
        XCTAssertEqual(marked.width, cg.width)
        XCTAssertEqual(marked.height, cg.height)
        // Encode round-trip proves the watermarked bitmap is a valid image.
        let data = try DAMEditRenderer.encode(
            marked, format: .png, quality: 1.0,
            sourceURL: URL(fileURLWithPath: "/tmp/x.png"), metadataPolicy: .none)
        XCTAssertGreaterThan(data.count, 100)
    }

    // MARK: - Watermark position geometry

    func testWatermarkPositionsStayOnCanvas() {
        let canvas = CGSize(width: 1000, height: 500)
        let text = CGSize(width: 200, height: 40)
        let margin: CGFloat = 30
        for position in DAMExportPreset.WatermarkSettings.Position.allCases {
            let point = position.point(canvas: canvas, textSize: text, margin: margin)
            XCTAssertGreaterThanOrEqual(point.x, 0, "\(position) off-canvas left")
            XCTAssertGreaterThanOrEqual(point.y, 0, "\(position) off-canvas bottom")
            XCTAssertLessThanOrEqual(point.x + text.width, canvas.width,
                                     "\(position) off-canvas right")
            XCTAssertLessThanOrEqual(point.y + text.height, canvas.height,
                                     "\(position) off-canvas top")
        }
        // Spot-check the geometry: bottomRight hugs the trailing edge.
        let br = DAMExportPreset.WatermarkSettings.Position.bottomRight
            .point(canvas: canvas, textSize: text, margin: margin)
        XCTAssertEqual(br.x, canvas.width - margin - text.width, accuracy: 0.01)
        XCTAssertEqual(br.y, margin, accuracy: 0.01)
    }
}
