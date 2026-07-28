import Foundation

/// Placeholder for NDI network capture sources.
/// NDI SDK integration is deferred until the NDI runtime is available.
@MainActor
final class NDICaptureSource: CaptureSource, @unchecked Sendable {
    let id: CaptureSourceID
    let name: String
    let type: CaptureSourceType = .ndi
    let supportsStillCapture: Bool = true

    private(set) var status: CaptureSourceStatus = .idle

    let previewStream: AsyncStream<Data>
    private let previewContinuation: AsyncStream<Data>.Continuation

    init(id: CaptureSourceID, name: String) {
        self.id = id
        self.name = name

        var continuation: AsyncStream<Data>.Continuation?
        self.previewStream = AsyncStream { cont in
            continuation = cont
        }
        self.previewContinuation = continuation!
    }

    func startPreview() async throws {
        throw CaptureSourceError.unsupportedConfiguration("NDI capture requires the NDI SDK to be linked.")
    }

    func stopPreview() async {
        status = .idle
    }

    func captureStill(to destination: URL) async throws -> CapturedImage {
        throw CaptureSourceError.unsupportedConfiguration("NDI capture not yet implemented.")
    }

    func disconnect() async {
        await stopPreview()
    }
}

/// Enumerator for NDI sources (stub: returns empty).
@MainActor
struct NDISourceEnumerator: CaptureSourceEnumerator, @unchecked Sendable {
    let sourceType: CaptureSourceType = .ndi

    func discover() async -> CaptureSourceDiscovery {
        // TODO: Integrate NDI SDK find service.
        return .available([])
    }
}

/// Placeholder for DJI/action cameras exposed as UVC webcams.
/// This will be handled by `AVCaptureSourceEnumerator` as a `.webcam` or `.djiWebcam` type.
/// Kept as a dedicated type for future per-device quirks.
@MainActor
final class DJICaptureSource: CaptureSource, @unchecked Sendable {
    let id: CaptureSourceID
    let name: String
    let type: CaptureSourceType = .djiWebcam
    let supportsStillCapture: Bool = false

    private(set) var status: CaptureSourceStatus = .idle

    let previewStream: AsyncStream<Data>
    private let previewContinuation: AsyncStream<Data>.Continuation

    init(id: CaptureSourceID, name: String) {
        self.id = id
        self.name = name

        var continuation: AsyncStream<Data>.Continuation?
        self.previewStream = AsyncStream { cont in
            continuation = cont
        }
        self.previewContinuation = continuation!
    }

    func startPreview() async throws {
        throw CaptureSourceError.unsupportedConfiguration("DJI source is managed through AVFoundation webcam enumeration.")
    }

    func stopPreview() async {
        status = .idle
    }

    func captureStill(to destination: URL) async throws -> CapturedImage {
        throw CaptureSourceError.unsupportedConfiguration("DJI action cameras do not expose still capture over UVC.")
    }

    func disconnect() async {
        await stopPreview()
    }
}
