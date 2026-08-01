import Foundation
import AppKit

/// PTP/USB source backed by the gphoto2 command-line tool.
/// Supports Nikon D90/D7000 and Sony A7R II via libgphoto2.
@MainActor
final class PTPCaptureSource: CaptureSource, @unchecked Sendable {
    let id: CaptureSourceID
    let name: String
    let type: CaptureSourceType = .ptpUSB
    let supportsStillCapture: Bool = true

    private(set) var status: CaptureSourceStatus = .idle

    private let port: String?
    private let gphotoPath: String
    private var previewTask: Task<Void, Never>?
    private let previewContinuation: AsyncStream<Data>.Continuation
    let previewStream: AsyncStream<Data>

    init(id: CaptureSourceID, name: String, port: String? = nil, gphotoPath: String = "/opt/homebrew/bin/gphoto2") {
        self.id = id
        self.name = name
        self.port = port
        self.gphotoPath = gphotoPath

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
            try await run(["--summary"], timeout: 10)
            status = .previewing
            startPreviewTask()
        } catch {
            status = .error(map(error).localizedDescription)
            throw error
        }
    }

    func stopPreview() async {
        previewTask?.cancel()
        previewTask = nil
        status = .idle
    }

    func captureStill(to destination: URL) async throws -> CapturedImage {
        status = .capturing
        defer { status = .previewing }

        let target = destination.appendingPathComponent("capture_\(UUID().uuidString).jpg")

        var args = ["--capture-image-and-download", "--filename", target.path]
        if let port = port {
            args += ["--port", port]
        }

        try await run(args, timeout: 60)

        return CapturedImage(
            sourceID: id,
            sourceName: name,
            fileURL: target,
            fileType: .jpeg,
            metadata: [
                "port": port ?? "auto",
                "backend": "gphoto2"
            ]
        )
    }

    func disconnect() async {
        await stopPreview()
    }

    // MARK: - gphoto2 CLI helpers

    private func run(_ args: [String], timeout: TimeInterval) async throws {
        let gphotoPath = self.gphotoPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gphotoPath)
                process.arguments = args

                let output = Pipe()
                let error = Pipe()
                process.standardOutput = output
                process.standardError = error

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                    process.terminate()
                }
                process.waitUntilExit()
                timer.invalidate()

                let status = process.terminationStatus
                if status != 0 {
                    let errData = error.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "gphoto2 exited with status \(status)"
                    continuation.resume(throwing: CaptureSourceError.captureFailed(message))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func startPreviewTask() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                do {
                    let data = try await self.capturePreview()
                    if !data.isEmpty {
                        self.previewContinuation.yield(data)
                    }
                } catch {
                    // Stream stays alive; brief pause before retry.
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    private func capturePreview() async throws -> Data {
        let gphotoPath = self.gphotoPath
        let port = self.port
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var args = ["--capture-preview", "--stdout"]
                if let port = port {
                    args += ["--port", port]
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: gphotoPath)
                process.arguments = args

                let output = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = output
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: errData, encoding: .utf8) ?? "preview failed"
                    continuation.resume(throwing: CaptureSourceError.previewFailed(message))
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func map(_ error: Error) -> CaptureSourceError {
        if let capture = error as? CaptureSourceError { return capture }
        return .underlying(error)
    }
}

/// Enumerates USB PTP cameras via gphoto2 --auto-detect.
@MainActor
struct PTPSourceEnumerator: CaptureSourceEnumerator, @unchecked Sendable {
    let sourceType: CaptureSourceType = .ptpUSB
    private let gphotoPath: String

    init(gphotoPath: String = "/opt/homebrew/bin/gphoto2") {
        self.gphotoPath = gphotoPath
    }

    func discover() async -> CaptureSourceDiscovery {
        let text = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.gphotoPath)
                process.arguments = ["--auto-detect"]

                let output = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = output
                process.standardError = errorPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: "error:\(error.localizedDescription)")
                    return
                }

                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: text)
            }
        }

        if text.hasPrefix("error:") {
            return .error("Failed to run gphoto2: \(String(text.dropFirst(6)))")
        }
        return .available(parseAutoDetect(text))
    }
}

@MainActor
private func parseAutoDetect(_ text: String) -> [PTPCaptureSource] {
    var sources: [PTPCaptureSource] = []
    let lines = text.components(separatedBy: .newlines)
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        guard !trimmed.hasPrefix("Model") && !trimmed.hasPrefix("-") else { continue }

        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2 else { continue }
        // Format: "Model                          Port"
        let model = parts.dropLast().joined(separator: " ")
        let port = parts.last ?? "usb:"

        // Skip UVC/webcam devices that AVFoundation already handles (OBSBOT, FaceTime,
        // virtual cameras, HDMI capture cards, etc.) so they don't appear twice.
        let lower = model.lowercased()
        if lower.contains("obsbot") ||
           lower.contains("facetime") ||
           lower.contains("webcam") ||
           lower.contains("virtual camera") ||
           lower.contains("virtual cam") ||
           lower.contains("display camera") ||
           lower.contains("continuity") ||
           lower.contains("capture card") ||
           lower.contains("cam link") ||
           lower.contains("elgato") ||
           lower.contains("ndi") {
            continue
        }

        // Use a stable ID derived from the gphoto2 port so selection persists across discoveries.
        let source = PTPCaptureSource(
            id: CaptureSourceID("ptp:\(port)"),
            name: model,
            port: port
        )
        sources.append(source)
    }
    return sources
}
