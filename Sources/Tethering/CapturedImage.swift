import Foundation
import AppKit

/// A single frame or still captured from a tethered source.
struct CapturedImage: Identifiable, Sendable {
    let id: UUID
    let sourceID: CaptureSourceID
    let sourceName: String
    let captureDate: Date
    let fileURL: URL?
    let thumbnailData: Data?
    let fileType: CapturedFileType
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        sourceID: CaptureSourceID,
        sourceName: String,
        captureDate: Date = Date(),
        fileURL: URL? = nil,
        thumbnailData: Data? = nil,
        fileType: CapturedFileType = .jpeg,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.captureDate = captureDate
        self.fileURL = fileURL
        self.thumbnailData = thumbnailData
        self.fileType = fileType
        self.metadata = metadata
    }
}

enum CapturedFileType: String, Sendable, CaseIterable {
    case jpeg
    case raw
    case tiff
    case png
    case heif
    case videoFrame
}

enum CaptureSourceType: String, Sendable, CaseIterable {
    case ptpUSB       // gphoto2 / PTP over USB (DSLR/mirrorless)
    case hdmiCapture  // HDMI capture card (AVFoundation)
    case webcam       // Built-in / USB webcam (AVFoundation)
    case ndi          // NDI network source
    case djiWebcam    // DJI / action camera as UVC webcam
}

enum CaptureSourceStatus: Sendable, Equatable {
    case idle
    case connecting
    case previewing
    case capturing
    case error(String)
}

struct CaptureSourceID: Hashable, Sendable, RawRepresentable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init?(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum CaptureSourceDiscovery: Sendable {
    case available([any CaptureSource])
    case error(String)
}

/// Common preview resolution presets.
enum CapturePreviewResolution: String, Sendable, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case native = "Native"

    var jpegQuality: Double {
        switch self {
        case .low:    return 0.5
        case .medium: return 0.7
        case .high:   return 0.85
        case .native: return 0.95
        }
    }
}

enum CaptureStorageMode: String, Sendable, CaseIterable {
    case copyToFolder = "Copy to folder"
    case referenceOnly = "Reference only"
}
