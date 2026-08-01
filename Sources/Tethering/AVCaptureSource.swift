import Foundation
import AVFoundation
import AppKit

/// AVFoundation-backed source for HDMI capture cards, webcams, and UVC devices.
/// Supports live preview and grabbing still frames.
@MainActor
final class AVCaptureSource: CaptureSource, @unchecked Sendable {
    let id: CaptureSourceID
    let name: String
    let type: CaptureSourceType
    let supportsStillCapture: Bool = true

    private(set) var status: CaptureSourceStatus = .idle

    private let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoConnection: AVCaptureConnection?
    private var delegate: VideoSampleDelegate?

    let previewStream: AsyncStream<Data>
    private let previewContinuation: AsyncStream<Data>.Continuation

    init(id: CaptureSourceID, name: String, device: AVCaptureDevice, type: CaptureSourceType) {
        self.id = id
        self.name = name
        self.device = device
        self.type = type

        var continuation: AsyncStream<Data>.Continuation?
        self.previewStream = AsyncStream { cont in
            continuation = cont
        }
        self.previewContinuation = continuation!
    }

    func startPreview() async throws {
        guard status != .previewing else { return }
        status = .connecting

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CaptureSourceError.previewFailed("Cannot add device input")
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.alwaysDiscardsLateVideoFrames = true

            guard session.canAddOutput(output) else {
                throw CaptureSourceError.previewFailed("Cannot add video output")
            }
            session.addOutput(output)

            let delegate = VideoSampleDelegate(continuation: previewContinuation)
            let queue = DispatchQueue(label: "swiftmaestro.avcapture.\(id.rawValue)", qos: .userInteractive)
            output.setSampleBufferDelegate(delegate, queue: queue)
            self.videoOutput = output
            self.videoConnection = output.connection(with: .video)
            self.delegate = delegate

            session.startRunning()
            status = .previewing
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    func stopPreview() async {
        session.stopRunning()
        if let output = videoOutput {
            session.removeOutput(output)
        }
        if let input = session.inputs.first {
            session.removeInput(input)
        }
        videoOutput = nil
        videoConnection = nil
        delegate = nil
        status = .idle
    }

    func captureStill(to destination: URL) async throws -> CapturedImage {
        status = .capturing
        defer { status = .previewing }

        guard let frame = delegate?.latestFrame else {
            throw CaptureSourceError.captureFailed("No preview frame available")
        }

        let target = destination.appendingPathComponent("frame_\(UUID().uuidString).jpg")
        guard FileManager.default.createFile(atPath: target.path, contents: frame, attributes: nil) else {
            throw CaptureSourceError.captureFailed("Failed to write frame")
        }

        return CapturedImage(
            sourceID: id,
            sourceName: name,
            fileURL: target,
            fileType: .videoFrame,
            metadata: [
                "deviceID": device.uniqueID,
                "backend": "avfoundation"
            ]
        )
    }

    func disconnect() async {
        await stopPreview()
    }
}

// MARK: - Sample delegate

private final class VideoSampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let continuation: AsyncStream<Data>.Continuation
    private var latestFrameData: Data?
    private let lock = NSLock()

    var latestFrame: Data? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrameData
    }

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = NSSize(width: cgImage.width, height: cgImage.height)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }

        lock.lock()
        latestFrameData = jpeg
        lock.unlock()

        continuation.yield(jpeg)
    }
}

// MARK: - Enumerator

@MainActor
struct AVCaptureSourceEnumerator: CaptureSourceEnumerator, @unchecked Sendable {
    let sourceType: CaptureSourceType = .hdmiCapture
    private let mediaType: AVMediaType = .video

    func discover() async -> CaptureSourceDiscovery {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .external,
            .builtInWideAngleCamera,
            .continuityCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: mediaType,
            position: .unspecified
        )

        var sources: [AVCaptureSource] = []
        for device in discovery.devices {
            let inferredType = inferredType(for: device)
            // Use the device's uniqueID so selection persists across discovery runs.
            let source = AVCaptureSource(
                id: CaptureSourceID(device.uniqueID),
                name: device.localizedName,
                device: device,
                type: inferredType
            )
            sources.append(source)
        }

        return .available(sources)
    }

    private func inferredType(for device: AVCaptureDevice) -> CaptureSourceType {
        let name = device.localizedName.lowercased()
        if name.contains("facetime") ||
           name.contains("built-in") ||
           name.contains("continuity") ||
           name.contains("webcam") ||
           name.contains("obsbot") {
            return .webcam
        }
        return .hdmiCapture
    }
}
