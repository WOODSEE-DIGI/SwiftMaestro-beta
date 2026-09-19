import Foundation
import Vision
import AppKit
import CoreGraphics

// MARK: - AI Redaction Detector
//
// Detects regions that commonly contain PII or other sensitive content using
// Apple Vision — fast, on-device, and accurate for bounding boxes. Results are
// returned as normalized DAMEditState.RedactionBox values that can be added to
// a redaction layer for review before export.
//
// Engines:
//   - Faces (VNDetectFaceRectanglesRequest)
//   - Text / OCR (VNRecognizeTextRequest with bounding boxes)
//   - Barcodes & QR codes (VNDetectBarcodesRequest)
//
// A Vision-Language model (VisionProxy) can be wired in later as an optional
// secondary engine for semantic categories Vision does not natively cover
// (e.g. "license plates", "ID cards").

actor DAMRedactionDetectorService {

    static let shared = DAMRedactionDetectorService()

    /// What the detector should look for.
    struct Options: Sendable, Equatable {
        var detectFaces = true
        var detectText = false
        var detectBarcodes = false
        /// Optional regex patterns. When provided, only text regions matching
        /// at least one pattern are redacted; otherwise all text regions are
        /// redacted. Useful for emails, phone numbers, SSNs, etc.
        var textPatterns: [String] = []
        /// Minimum confidence (0…1) for a detection to be kept.
        var minimumConfidence: Double = 0.3
        /// Kind applied to AI-detected boxes.
        var kind: DAMEditState.RedactionBox.Kind = .blur

        static let `default` = Options()

        /// Common PII regex patterns for text redaction.
        /// Patterns may use a capture group; when group 1 is present, only the
        /// captured value is redacted, leaving labels such as "VIN:" readable.
        static let piiPatterns: [String] = [
            // Email, phone, date, address
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"\b(?:\+?\d{1,3}[-.\s]?)?\(?\d{2,4}\)?[-.\s]?\d{3,4}[-.\s]?\d{3,4}\b"#,
            #"\b\d{1,2}[/-]\d{1,2}[/-]\d{2,4}\b"#,
            #"\b\d{1,3}\s+[^,\d]{2,30}(?:street|st|road|rd|avenue|ave|drive|dr|lane|ln|court|ct|place|pl|way|boulevard|blvd)\b"#,

            // Vehicle / registration identifiers (label-driven, group 1 = value)
            #"(?:VIN|Vehicle\s+ID|Vehicle\s+Identification\s+Number)[\s:#]*([A-HJ-NPR-Z0-9]{17})"#,
            #"(?:Registration\s+(?:Number|No\.?)|Rego|Reg\.?|Plate|Licence\s+Plate|License\s+Plate|Number\s+Plate)[\s:#]*([A-Z0-9]{3,8})"#,

            // Document / transaction identifiers (label-driven)
            #"(?:Certificate\s+(?:ID|Number)|Transaction\s+(?:ID|Number)|Ref(?:erence)?\s*(?:Number|No)?|Invoice\s*(?:Number|No)?)[\s:#]*(\d[\d\s\-]{5,30})"#,

            // Government / tax identifiers (label-driven)
            #"(?:SSN|Social\s+Security\s*(?:Number|No)?)[\s:#]*(\d{3}[\-\s]\d{2}[\-\s]\d{4})"#, // US SSN
            #"(?:ABN|Australian\s+Business\s+Number)[\s:#]*(\d{2}\s*\d{3}\s*\d{3}\s*\d{3})"#, // AU ABN
            #"(?:ACN|Australian\s+Company\s+Number)[\s:#]*(\d{3}\s*\d{3}\s*\d{3})"#,           // AU ACN
            #"(?:TFN|Tax\s+File\s*(?:Number|No)?)[\s:#]*(\d{3}[\-\s]\d{3}[\-\s]\d{3})"#,      // AU TFN
            #"(?:CRN|Customer\s+Reference\s*(?:Number|No)?|Centrelink|Customer\s+Number)[\s:#]*(\d{3}\s*\d{3}\s*\d{3})"#, // AU Centrelink CRN
            #"(?:Medicare\s*(?:Number|No)?|Medicare)[\s:#]*(\d{4}\s*\d{5}\s*\d{1})"#,           // AU Medicare
            #"(?:Passport\s*(?:Number|No)?|PP\s*No)[\s:#]*([A-Z]{1,2}\d{6,9})"#,                  // Passport numbers
            #"(?:Concession|Health\s+Care|Pensioner|Veteran|Senior)[\s:#]*([A-Z0-9]{6,14})"#,       // Govt concession/cards

            // Driver licence & related permits (label-driven; formats vary by state/country)
            #"(?:Licence|License|Lic\s*No|Licence\s*Number|License\s*Number|Driver\s*Lic|DL|Learner\s*Permit)[\s:#]*([A-Z0-9]{5,14})"#,
            #"(?:Working\s*With\s*Children|WWCC|Police\s*Check|Firearms\s*Lic|Proof\s*Of\s*Age)[\s:#]*([A-Z0-9]{5,14})"#,

            // Banking identifiers (label-driven)
            #"(?:Bank\s+Account|Account\s*(?:Number|No)?|Acct\.?|Acct\s*No)[\s:#]*(\d[\d\s\-]{5,20})"#,
            #"(?:BSB)[\s:#]*(\d{3}[\-\s]\d{3})"#,

            // Standalone heuristics (no capture group — redact the whole match)
            #"\b[A-HJ-NPR-Z0-9]{17}\b"#,                         // standalone VIN
            #"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{4}\b"#    // credit-card-like blocks
        ]
    }

    enum DetectorError: Error {
        case cannotLoadImage
        case visionFailed(Error)
    }

    /// Detect redaction regions in an image file.
    func detect(
        at path: String,
        options: Options = .default
    ) async throws -> [DAMEditState.RedactionBox] {
        guard FileManager.default.fileExists(atPath: path),
              let cgImage = await loadCGImage(path: path, maxPixel: 8192)
        else {
            throw DetectorError.cannotLoadImage
        }
        return try detect(cgImage: cgImage, options: options)
    }

    /// Detect redaction regions from image data.
    func detect(
        imageData: Data,
        options: Options = .default
    ) async throws -> [DAMEditState.RedactionBox] {
        guard let cgImage = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithData(imageData as CFData, nil)!, 0, nil)
        else {
            throw DetectorError.cannotLoadImage
        }
        return try detect(cgImage: cgImage, options: options)
    }

    /// Run Vision requests on a CGImage and convert observations to boxes.
    private nonisolated func detect(
        cgImage: CGImage,
        options: Options
    ) throws -> [DAMEditState.RedactionBox] {
        let fullBoxes = try detectSingle(cgImage: cgImage, options: options)

        // For large images, also run a tiled face pass so small or grid-line
        // faces get a second chance at a larger relative scale.
        let width = cgImage.width
        let height = cgImage.height
        let maxDim = max(width, height)
        guard options.detectFaces, maxDim > 2048 else {
            return fullBoxes
        }

        let tileCount = maxDim > 4096 ? 3 : 2
        let tiledBoxes = try detectTiledFaces(
            cgImage: cgImage,
            tileCount: tileCount,
            options: options
        )
        return mergeBoxes(fullBoxes + tiledBoxes, iouThreshold: 0.5)
    }

    /// Run one detection pass on a single CGImage.
    private nonisolated func detectSingle(
        cgImage: CGImage,
        options: Options
    ) throws -> [DAMEditState.RedactionBox] {
        let requests = buildRequests(options: options)
        guard !requests.isEmpty else { return [] }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            throw DetectorError.visionFailed(error)
        }

        var boxes: [DAMEditState.RedactionBox] = []
        for request in requests {
            switch request {
            case let faceRequest as VNDetectFaceRectanglesRequest:
                boxes.append(contentsOf: faceBoxes(from: faceRequest, options: options))
            case let textRequest as VNRecognizeTextRequest:
                boxes.append(contentsOf: textBoxes(from: textRequest, options: options))
            case let barcodeRequest as VNDetectBarcodesRequest:
                boxes.append(contentsOf: barcodeBoxes(from: barcodeRequest, options: options))
            default:
                break
            }
        }
        return boxes
    }

    /// Run face detection on overlapping tiles and convert local coordinates
    /// back to image-normalized coordinates.
    private nonisolated func detectTiledFaces(
        cgImage: CGImage,
        tileCount: Int,
        options: Options
    ) throws -> [DAMEditState.RedactionBox] {
        let width = Double(cgImage.width)
        let height = Double(cgImage.height)
        let tileW = width / Double(tileCount)
        let tileH = height / Double(tileCount)
        let overlap = 0.25 // 25% overlap between neighbouring tiles

        var allBoxes: [DAMEditState.RedactionBox] = []

        for row in 0..<tileCount {
            for col in 0..<tileCount {
                let x0 = Double(col) * tileW - tileW * overlap / 2
                let y0 = Double(row) * tileH - tileH * overlap / 2
                let x = max(0, x0)
                let y = max(0, y0)
                let w = min(width - x, tileW * (1 + overlap))
                let h = min(height - y, tileH * (1 + overlap))

                let pixelRect = CGRect(x: x, y: y, width: w, height: h)
                guard let tile = cgImage.cropping(to: pixelRect) else { continue }

                let faceOptions = Options(
                    detectFaces: true,
                    detectText: false,
                    detectBarcodes: false,
                    textPatterns: [],
                    minimumConfidence: options.minimumConfidence,
                    kind: options.kind
                )
                let boxes = try detectSingle(cgImage: tile, options: faceOptions)
                let offsetX = x / width
                let offsetY = y / height
                let scaleX = w / width
                let scaleY = h / height

                for var box in boxes {
                    box.rect.x = offsetX + box.rect.x * scaleX
                    box.rect.y = offsetY + box.rect.y * scaleY
                    box.rect.width *= scaleX
                    box.rect.height *= scaleY
                    allBoxes.append(box)
                }
            }
        }
        return allBoxes
    }

    /// Merge boxes using non-maximum suppression based on IOU.
    private nonisolated func mergeBoxes(
        _ boxes: [DAMEditState.RedactionBox],
        iouThreshold: Double
    ) -> [DAMEditState.RedactionBox] {
        let sorted = boxes.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
        var kept: [DAMEditState.RedactionBox] = []
        for candidate in sorted {
            let overlaps = kept.contains { keptBox in
                DAMEditState.iou(candidate.rect, keptBox.rect) > iouThreshold
            }
            if !overlaps {
                kept.append(candidate)
            }
        }
        return kept
    }

    private nonisolated func buildRequests(options: Options) -> [VNRequest] {
        var requests: [VNRequest] = []
        if options.detectFaces {
            let faceRequest = VNDetectFaceRectanglesRequest()
            faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
            requests.append(faceRequest)
        }
        if options.detectText {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = true
            requests.append(textRequest)
        }
        if options.detectBarcodes {
            let barcodeRequest = VNDetectBarcodesRequest()
            requests.append(barcodeRequest)
        }
        return requests
    }

    // MARK: - Face detection

    private nonisolated func faceBoxes(
        from request: VNDetectFaceRectanglesRequest,
        options: Options
    ) -> [DAMEditState.RedactionBox] {
        guard let results = request.results as? [VNFaceObservation] else { return [] }
        return results
            .filter { Double($0.confidence) >= options.minimumConfidence }
            .map { observation in
                box(from: observation.boundingBox, kind: options.kind)
            }
    }

    // MARK: - Text detection

    private nonisolated func textBoxes(
        from request: VNRecognizeTextRequest,
        options: Options
    ) -> [DAMEditState.RedactionBox] {
        guard let results = request.results as? [VNRecognizedTextObservation] else { return [] }

        let patterns: [(regex: NSRegularExpression, hasCapture: Bool)] = options.textPatterns.compactMap { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (regex, regex.numberOfCaptureGroups > 0)
        }

        return results.compactMap { observation -> [DAMEditState.RedactionBox]? in
            guard Double(observation.confidence) >= options.minimumConfidence,
                  let candidate = observation.topCandidates(1).first else { return nil }

            let string = candidate.string

            // No patterns selected → redact every recognized text region.
            if patterns.isEmpty {
                return [box(from: observation.boundingBox, kind: options.kind)]
            }

            let fullRange = NSRange(string.startIndex..., in: string)
            var matchedBoxes: [DAMEditState.RedactionBox] = []

            for (regex, hasCapture) in patterns {
                let matches = regex.matches(in: string, options: [], range: fullRange)
                for match in matches {
                    let targetRange: NSRange
                    if hasCapture, match.numberOfRanges > 1,
                       match.range(at: 1).location != NSNotFound {
                        targetRange = match.range(at: 1)
                    } else {
                        targetRange = match.range
                    }
                    guard let stringRange = Range(targetRange, in: string),
                          let rectObservation = try? candidate.boundingBox(for: stringRange) else { continue }
                    matchedBoxes.append(box(from: rectObservation.boundingBox, kind: options.kind))
                }
            }

            return matchedBoxes.isEmpty ? nil : matchedBoxes
        }.flatMap { $0 }
    }

    // MARK: - Barcode detection

    private nonisolated func barcodeBoxes(
        from request: VNDetectBarcodesRequest,
        options: Options
    ) -> [DAMEditState.RedactionBox] {
        guard let results = request.results as? [VNBarcodeObservation] else { return [] }
        return results
            .filter { Double($0.confidence) >= options.minimumConfidence }
            .map { observation in
                box(from: observation.boundingBox, kind: options.kind)
            }
    }

    // MARK: - Helpers

    /// Vision uses bottom-left-origin normalized rects; the redaction recipe
    /// uses top-left-origin normalized rects (the displayed frame).
    private nonisolated func box(
        from visionRect: CGRect,
        kind: DAMEditState.RedactionBox.Kind
    ) -> DAMEditState.RedactionBox {
        let rect = DAMEditState.CropRect(
            x: visionRect.minX,
            y: 1.0 - visionRect.minY - visionRect.height,
            width: visionRect.width,
            height: visionRect.height
        )
        return DAMEditState.RedactionBox(rect: rect, kind: kind)
    }

    /// Load a CGImage, downscaled if needed, matching the tagging service path.
    private nonisolated func loadCGImage(path: String, maxPixel: Int) async -> CGImage? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        if DAMFileKind.isCameraRAW(url) {
            guard let data = try? RAWPreviewDecoder.jpegPreviewForRAW(
                atPath: path, maxPixelSize: CGFloat(maxPixel)),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return image
        }

        if DAMFileKind.isPDF(url) {
            return try? DocumentThumbService.pdfCGImage(url: url, maxPixelSize: maxPixel)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
