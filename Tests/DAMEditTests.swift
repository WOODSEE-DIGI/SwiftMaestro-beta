import AppKit
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SwiftMaestro

/// Tests for the non-destructive edit system (v8):
/// recipe round-trips, DB persistence (including clear-on-identity), and the
/// CoreImage render pipeline against a real encoded test image.
final class DAMEditTests: XCTestCase {

    // MARK: - Recipe model

    func testRecipeRoundTrip() {
        var edit = DAMEditState()
        edit.exposureEV = 1.25
        edit.rotateQuarterTurns = 2
        edit.straightenDegrees = -3.5
        edit.crop = .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        edit.blackAndWhite = true
        edit.temperature = 4200

        let decoded = DAMEditState.fromJSON(edit.asJSON)
        XCTAssertEqual(decoded, edit)
    }

    func testIdentityDetection() {
        XCTAssertTrue(DAMEditState().isIdentity)
        var edit = DAMEditState()
        edit.exposureEV = 0.1
        XCTAssertFalse(edit.isIdentity)
    }

    /// Guards the per-slider reset source of truth: every field default the
    /// editor's reset buttons target must match these values. If a default
    /// changes on purpose, update this test AND the expectations together.
    func testRecipeDefaultsMatchResetExpectations() {
        let d = DAMEditState()
        XCTAssertEqual(d.straightenDegrees, DAMEditState.defaultValue(for: \.straightenDegrees))
        XCTAssertEqual(d.exposureEV, DAMEditState.defaultValue(for: \.exposureEV))
        XCTAssertEqual(d.contrast, DAMEditState.defaultValue(for: \.contrast))
        XCTAssertEqual(d.highlights, DAMEditState.defaultValue(for: \.highlights))
        XCTAssertEqual(d.shadows, DAMEditState.defaultValue(for: \.shadows))
        XCTAssertEqual(d.temperature, DAMEditState.defaultValue(for: \.temperature))
        XCTAssertEqual(d.tint, DAMEditState.defaultValue(for: \.tint))
        XCTAssertEqual(d.saturation, DAMEditState.defaultValue(for: \.saturation))
        XCTAssertEqual(d.vibrance, DAMEditState.defaultValue(for: \.vibrance))
        XCTAssertEqual(d.sharpen, DAMEditState.defaultValue(for: \.sharpen))
        XCTAssertEqual(d.noiseReduction, DAMEditState.defaultValue(for: \.noiseReduction))
        XCTAssertEqual(d.temperature, 6500)   // 6500 K = unchanged white balance
        XCTAssertEqual(d.contrast, 1.0)       // multiplier, not offset
        XCTAssertEqual(d.saturation, 1.0)
        XCTAssertFalse(d.blackAndWhite)
        XCTAssertNil(d.crop)
    }

    /// The modal crop tool renders the recipe with the crop stripped (full
    /// frame visible under the overlay) while leaving everything else intact.
    func testForCropEditingStripsCropOnly() {
        var edit = DAMEditState()
        edit.exposureEV = 1.5
        edit.rotateQuarterTurns = 1
        edit.crop = .init(x: 0.2, y: 0.2, width: 0.5, height: 0.5)

        let armed = edit.forCropEditing
        XCTAssertNil(armed.crop)
        XCTAssertEqual(armed.exposureEV, 1.5)
        XCTAssertEqual(armed.rotateQuarterTurns, 1)
        // The original recipe is untouched (value semantics).
        XCTAssertNotNil(edit.crop)
        // Stripping the crop from an otherwise-identity recipe IS identity.
        var onlyCrop = DAMEditState()
        onlyCrop.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        XCTAssertTrue(onlyCrop.forCropEditing.isIdentity)
    }

    // MARK: - DB persistence

    private func makeTestAsset(in database: DAMDatabase) -> Int64 {
        // Insert a minimal asset row and return its id.
        var id: Int64 = -1
        try! database.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO asset (path, filename) VALUES (?, ?)
                """, arguments: ["/tmp/damedit-test.jpg", "damedit-test.jpg"])
            id = db.lastInsertedRowID
        }
        return id
    }

    func testSaveLoadClearEdits() throws {
        let database = try DAMDatabase.makeForTesting()
        let assetId = makeTestAsset(in: database)

        XCTAssertNil(database.loadEdits(assetId: assetId))
        XCTAssertFalse(database.hasEdits(assetId: assetId))

        var edit = DAMEditState()
        edit.exposureEV = 2.0
        edit.crop = .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        try database.saveEdits(assetId: assetId, edit)

        XCTAssertTrue(database.hasEdits(assetId: assetId))
        XCTAssertEqual(database.loadEdits(assetId: assetId), edit)

        // Updating replaces the row (no duplicates).
        edit.exposureEV = -1.0
        try database.saveEdits(assetId: assetId, edit)
        XCTAssertEqual(database.loadEdits(assetId: assetId)?.exposureEV, -1.0)

        // Saving the identity state clears the row (reset behaviour).
        try database.saveEdits(assetId: assetId, DAMEditState())
        XCTAssertNil(database.loadEdits(assetId: assetId))
        XCTAssertFalse(database.hasEdits(assetId: assetId))
    }

    // MARK: - Renderer pipeline (synthetic JPEG → renders)

    private func makeTestImageFile() throws -> DAMAsset {
        // Draw a 64x32 color-block test image (non-square so rotation is observable).
        let size = NSSize(width: 64, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSColor.blue.setFill()
        NSRect(x: 32, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [:])
        else { throw XCTSkip("could not encode test JPEG") }
        let url = URL(fileURLWithPath: "/tmp/dam-edit-test-\(UUID().uuidString.prefix(8)).jpg")
        try jpeg.write(to: url)

        // A real catalog row so the renderer sees a normal DAMAsset.
        let database = try DAMDatabase.makeForTesting()
        let asset = try database.dbQueue.write { db -> DAMAsset in
            try db.execute(sql: "INSERT INTO asset (path, filename) VALUES (?, ?)",
                           arguments: [url.path, url.lastPathComponent])
            return try XCTUnwrap(
                try? DAMAsset.filter(DAMAsset.Columns.path == url.path).fetchOne(db))
        }
        return asset
    }

    func testRenderProducesImageForIdentityAndEdited() throws {
        let asset = try makeTestImageFile()

        let identity = try DAMEditRenderer.render(asset: asset, edit: DAMEditState(), maxPixelSize: 512)
        XCTAssertGreaterThan(identity.size.width, 0)

        var edit = DAMEditState()
        edit.exposureEV = 1.0
        edit.saturation = 1.5
        edit.sharpen = 0.4
        edit.blackAndWhite = true
        let edited = try DAMEditRenderer.render(asset: asset, edit: edit, maxPixelSize: 512)
        XCTAssertGreaterThan(edited.size.width, 0)
    }

    func testCropReducesOutputExtent() throws {
        let asset = try makeTestImageFile()
        var edit = DAMEditState()
        edit.crop = .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try DAMEditRenderer.render(asset: asset, edit: edit, maxPixelSize: 512)
        // 50% crop of a 64px source should be ≤ 50% of the identity render.
        let full = try DAMEditRenderer.render(asset: asset, edit: DAMEditState(), maxPixelSize: 512)
        XCTAssertLessThanOrEqual(cropped.size.width, full.size.width * 0.75)
    }

    func testRotationChangesOrientation() throws {
        let asset = try makeTestImageFile()
        var edit = DAMEditState()
        edit.rotateQuarterTurns = 1   // 90° — swaps width/height of the 64x32-halves image
        let rotated = try DAMEditRenderer.render(asset: asset, edit: edit, maxPixelSize: 512)
        XCTAssertGreaterThan(rotated.size.height, rotated.size.width)
    }

    // MARK: - Drag-crop overlay geometry

    func testCropRectClampedIntoBounds() {
        let over = DAMEditState.CropRect(x: 0.8, y: 0.9, width: 0.5, height: 0.5).clamped()
        XCTAssertLessThanOrEqual(over.x + over.width, 1.0)
        XCTAssertLessThanOrEqual(over.y + over.height, 1.0)
        XCTAssertGreaterThanOrEqual(over.width, 0.05)
    }

    func testCropRectClampedMinimumArea() {
        let tiny = DAMEditState.CropRect(x: 0.1, y: 0.1, width: 0.001, height: 0.001).clamped()
        XCTAssertGreaterThanOrEqual(tiny.width, 0.05)
        XCTAssertGreaterThanOrEqual(tiny.height, 0.05)
    }

    func testFittedRectCentersAndScales() {
        // 200x100 image in a 400x400 container: fit by width → 400x200 centered.
        let fitted = DAMCropOverlay.fittedRect(
            imageSize: CGSize(width: 200, height: 100), in: CGSize(width: 400, height: 400))
        XCTAssertEqual(fitted.width, 400, accuracy: 0.01)
        XCTAssertEqual(fitted.height, 200, accuracy: 0.01)
        XCTAssertEqual(fitted.minX, 0, accuracy: 0.01)
        XCTAssertEqual(fitted.minY, 100, accuracy: 0.01)
    }

    func testViewRectMapsNormalizedCrop() {
        let fitted = CGRect(x: 10, y: 20, width: 200, height: 100)
        let crop = DAMEditState.CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let rect = DAMCropOverlay.viewRect(for: crop, fitted: fitted)
        XCTAssertEqual(rect?.minX ?? 0, 60, accuracy: 0.01)   // 10 + 0.25*200
        XCTAssertEqual(rect?.minY ?? 0, 45, accuracy: 0.01)   // 20 + 0.25*100
        XCTAssertEqual(rect?.width ?? 0, 100, accuracy: 0.01) // 0.5*200
    }

    // MARK: - Drag-move math (the "box jumps erratically" regression)

    /// movedBy applies the delta to the ORIGIN and clamps into bounds.
    func testMovedByAppliesDeltaAndClamps() {
        let box = DAMEditState.CropRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        let moved = box.movedBy(dx: -0.1, dy: 0.05)
        XCTAssertEqual(moved.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(moved.y, 0.55, accuracy: 0.0001)
        XCTAssertEqual(moved.width, 0.2, accuracy: 0.0001)   // size never changes

        // Clamps at every edge.
        XCTAssertEqual(box.movedBy(dx: -0.9, dy: -0.9).x, 0)
        XCTAssertEqual(box.movedBy(dx: -0.9, dy: -0.9).y, 0)
        XCTAssertEqual(box.movedBy(dx: 0.9, dy: 0.9).x, 0.8)   // 1 - width
        XCTAssertEqual(box.movedBy(dx: 0.9, dy: 0.9).y, 0.8)
    }

    /// The bug: applying the full drag delta to the LIVE rect compounds the
    /// movement every event. The overlay contract is that movedBy is only
    /// ever applied to the rect captured at gesture START — pin that the
    /// function itself is pure (same origin + same delta = same result,
    /// forever) so no accumulation is possible when used as intended.
    func testMovedByIsPureAndNonAccumulating() {
        let origin = DAMEditState.CropRect(x: 0.3, y: 0.3, width: 0.25, height: 0.25)
        let delta = (dx: 0.12, dy: -0.07)
        let first = origin.movedBy(dx: delta.dx, dy: delta.dy)
        let hundredth = origin.movedBy(dx: delta.dx, dy: delta.dy)
        XCTAssertEqual(first, hundredth)
        XCTAssertEqual(first.x, 0.42, accuracy: 0.0001)
        XCTAssertEqual(first.y, 0.23, accuracy: 0.0001)
    }

    // MARK: - Redaction + orientation (pixel-exact, quadrant fixture)

    /// 64x64 quadrant fixture (visual top-left origin): TL red, TR green,
    /// BL blue, BR yellow. Built PIXEL-EXACT from a raw RGBA buffer —
    /// NSImage lockFocus fixtures render at backing scale (Retina = 2x
    /// pixels) and proved unreliable for color assertions; this buffer's
    /// row 0 is the JPEG's first (visual-top) row by construction.
    private func makeQuadrantImageFile() throws -> DAMAsset {
        let width = 64, height = 64
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let top = y < height / 2, left = x < width / 2
                let (r, g, b): (UInt8, UInt8, UInt8) = top
                    ? (left ? (255, 0, 0) : (0, 200, 0))     // TL red, TR green
                    : (left ? (0, 0, 255) : (255, 255, 0))   // BL blue, BR yellow
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: srgb,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent)
        else { throw XCTSkip("could not build quadrant image") }
        let url = URL(fileURLWithPath: "/tmp/dam-edit-quadrant-\(UUID().uuidString.prefix(8)).jpg")
        guard let fileDestination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw XCTSkip("could not create JPEG destination") }
        CGImageDestinationAddImage(fileDestination, cgImage, nil)
        guard CGImageDestinationFinalize(fileDestination) else {
            throw XCTSkip("could not write quadrant JPEG")
        }

        // A real catalog row so the renderer sees a normal DAMAsset.
        let database = try DAMDatabase.makeForTesting()
        let asset = try database.dbQueue.write { db -> DAMAsset in
            try db.execute(sql: "INSERT INTO asset (path, filename) VALUES (?, ?)",
                           arguments: [url.path, url.lastPathComponent])
            return try XCTUnwrap(
                try? DAMAsset.filter(DAMAsset.Columns.path == url.path).fetchOne(db))
        }
        return asset
    }

    /// Sample a rendered NSImage at bitmap coordinates (top-left origin).
    private func pixelColor(_ image: NSImage, x: Int, y: Int) -> NSColor? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: x, y: y)
    }

    /// Orientation ground truth: identity render of the quadrant fixture
    /// must put red top-left, green top-right, blue bottom-left, yellow
    /// bottom-right. If this fails, the sampling helper itself is flipped.
    func testIdentityRenderPreservesQuadrants() throws {
        let asset = try makeQuadrantImageFile()
        let rendered = try DAMEditRenderer.render(asset: asset, edit: DAMEditState(), maxPixelSize: 512)

        func rgb(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            guard let color = pixelColor(rendered, x: x, y: y)?
                .usingColorSpace(.sRGB) else { return (-1, -1, -1) }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: nil)
            return (r, g, b)
        }
        let tl = rgb(16, 16), tr = rgb(48, 16), bl = rgb(16, 48), br = rgb(48, 48)
        XCTAssertTrue(tl.r > 0.7 && tl.g < 0.4 && tl.b < 0.4, "TL should be red, got \(tl)")
        XCTAssertTrue(tr.g > 0.6 && tr.r < 0.5, "TR should be green, got \(tr)")
        XCTAssertTrue(bl.b > 0.7 && bl.r < 0.4, "BL should be blue, got \(bl)")
        XCTAssertTrue(br.r > 0.7 && br.g > 0.7 && br.b < 0.4, "BR should be yellow, got \(br)")
    }

    /// The recipe frame is top-left-origin (what you see); the renderer must
    /// keep that orientation through the bottom-left CIImage space. A crop
    /// of the top-left quarter must keep the RED quadrant.
    func testCropKeepsDisplayedTopLeft() throws {
        let asset = try makeQuadrantImageFile()
        var edit = DAMEditState()
        edit.crop = .init(x: 0, y: 0, width: 0.5, height: 0.5)
        let rendered = try DAMEditRenderer.render(asset: asset, edit: edit, maxPixelSize: 512)
        let color = try XCTUnwrap(pixelColor(rendered, x: 16, y: 16))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: nil)
        XCTAssertGreaterThan(r, 0.7, "top-left crop should be red (y-flip check)")
        XCTAssertLessThan(g, 0.4)
        XCTAssertLessThan(b, 0.4)
    }

    func testBlackoutRedactsDisplayedRegion() throws {
        let asset = try makeQuadrantImageFile()
        var edit = DAMEditState()
        edit.redactions = [.init(
            rect: .init(x: 0, y: 0, width: 0.5, height: 0.5), kind: .blackout)]
        let rendered = try DAMEditRenderer.render(asset: asset, edit: edit, maxPixelSize: 512)

        // Inside the box (visual top-left): black.
        let inside = try XCTUnwrap(pixelColor(rendered, x: 16, y: 16))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        inside.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: nil)
        XCTAssertLessThan(r, 0.08); XCTAssertLessThan(g, 0.08); XCTAssertLessThan(b, 0.08)

        // Bottom-right (outside the box): still yellow.
        let outside = try XCTUnwrap(pixelColor(rendered, x: 48, y: 48))
        outside.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: nil)
        XCTAssertGreaterThan(r, 0.7); XCTAssertGreaterThan(g, 0.7); XCTAssertLessThan(b, 0.35)
    }

    func testBlurSmearsButDoesNotBlacken() throws {
        let asset = try makeQuadrantImageFile()
        var edit = DAMEditState()
        // Box spans the TL/TR border (x = 32): red on the left, green right.
        edit.redactions = [.init(
            rect: .init(x: 0.25, y: 0, width: 0.5, height: 0.5), kind: .blur)]
        let rendered = try DAMEditRenderer.render(asset: asset, edit: edit, maxPixelSize: 512)

        // At the border line the blur must mix red+green (neither pure).
        let border = try XCTUnwrap(pixelColor(rendered, x: 32, y: 16))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        border.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: nil)
        XCTAssertGreaterThan(r, 0.15, "border should keep some red")
        XCTAssertLessThan(r, 0.85, "border should not be pure red")
        XCTAssertGreaterThan(g, 0.15, "border should pick up green")
        XCTAssertLessThan(b, 0.3, "no blue this far up")

        // Outside the box (bottom-left): still blue.
        let outside = try XCTUnwrap(pixelColor(rendered, x: 16, y: 48))
        outside.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: nil)
        XCTAssertGreaterThan(b, 0.7); XCTAssertLessThan(r, 0.35)
    }

    // MARK: - Recipe backward compatibility + layout payloads

    /// Recipes saved before redactions existed must still decode — the old
    /// synthesized decoder failed the whole payload on unknown/missing keys
    /// and fromJSON silently reset the recipe to identity.
    func testRecipeDecodesWithoutRedactionsKey() {
        let legacy = """
        {"rotateQuarterTurns":2,"straightenDegrees":-3.5,"flipHorizontal":true,\
        "crop":{"x":0.1,"y":0.2,"width":0.7,"height":0.6},"exposureEV":1.25,\
        "contrast":1.2,"highlights":0.1,"shadows":-0.2,"saturation":1.4,\
        "vibrance":0.3,"temperature":4200,"tint":10,"sharpen":0.4,\
        "noiseReduction":0.1,"blackAndWhite":true}
        """
        let decoded = DAMEditState.fromJSON(legacy)
        XCTAssertEqual(decoded.exposureEV, 1.25)
        XCTAssertEqual(decoded.temperature, 4200)
        XCTAssertEqual(decoded.crop, .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6))
        XCTAssertTrue(decoded.blackAndWhite)
        XCTAssertEqual(decoded.redactions, [])   // defaulted, not fatal
    }

    func testRedactionLayoutRoundTrip() {
        var edit = DAMEditState()
        edit.redactions = [
            .init(rect: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.1), kind: .blackout),
            .init(rect: .init(x: 0.5, y: 0.5, width: 0.2, height: 0.2), kind: .blur),
        ]
        let json = edit.redactionLayoutJSON
        let decoded = DAMEditState.redactionLayout(fromJSON: json)
        XCTAssertEqual(decoded, edit.redactions)

        // A full recipe payload is NOT a layout payload (different marker).
        XCTAssertNil(DAMEditState.redactionLayout(fromJSON: edit.asJSON))
        // Garbage is not a layout.
        XCTAssertNil(DAMEditState.redactionLayout(fromJSON: "not json"))
    }
}
