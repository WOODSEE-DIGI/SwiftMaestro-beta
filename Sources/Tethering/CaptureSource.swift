import Foundation
import AppKit

/// A pluggable source for tethered or live capture.
/// All capture sources run on the main actor because they drive SwiftUI state.
@MainActor
protocol CaptureSource: AnyObject, Sendable {
    var id: CaptureSourceID { get }
    var name: String { get }
    var type: CaptureSourceType { get }
    var status: CaptureSourceStatus { get }

    /// Emits the current preview frame as JPEG data. May be empty if source is not previewing.
    var previewStream: AsyncStream<Data> { get }

    /// True if the source can be triggered to capture a still.
    var supportsStillCapture: Bool { get }

    /// Begins the live preview stream.
    func startPreview() async throws

    /// Stops the live preview stream.
    func stopPreview() async

    /// Captures a single still. Returns metadata and a path to the downloaded file.
    /// The destination is provided by the session; the source may return nil
    /// if the source is video-only or does not store files.
    func captureStill(to destination: URL) async throws -> CapturedImage

    /// Release any underlying hardware handles.
    func disconnect() async
}

/// Default implementation for common derived properties.
extension CaptureSource {
    var isVideoOnly: Bool { !supportsStillCapture }

    /// True if the source name suggests it is an OBSBOT webcam (PTZ controls).
    var isObsbotDevice: Bool { name.lowercased().contains("obsbot") }
}

/// Discovery service that can enumerate supported sources on demand.
@MainActor
protocol CaptureSourceEnumerator: Sendable {
    func discover() async -> CaptureSourceDiscovery
    var sourceType: CaptureSourceType { get }
}

/// Errors thrown by capture sources.
enum CaptureSourceError: LocalizedError, Sendable {
    case notConnected
    case previewFailed(String)
    case captureFailed(String)
    case destinationNotWritable(URL)
    case unsupportedConfiguration(String)
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Capture source is not connected."
        case .previewFailed(let reason):
            return "Preview failed: \(reason)"
        case .captureFailed(let reason):
            return "Capture failed: \(reason)"
        case .destinationNotWritable(let url):
            return "Destination is not writable: \(url.path)"
        case .unsupportedConfiguration(let reason):
            return "Unsupported configuration: \(reason)"
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}
