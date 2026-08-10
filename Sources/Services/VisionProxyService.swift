import Foundation
import MLXLMCommon
import CoreImage
import AppKit
import Vision

// MARK: - Vision Proxy Service

/// Gives every model image understanding by routing attached images through a
/// high-quality MLX vision-language model (default: Qwen3-VL-8B-Instruct-4bit) and
/// handing the resulting text description to the primary model. Works in two modes:
///
/// - **In-process MLX**: loads the configured vision model into the same
///   `MLXInferenceEngine` residency cache as the main model. No subprocess, no Python
///   dependency.
/// - **Python Server** (default): spawns the embedded `fastvlm_server.py` as a
///   subprocess and calls its OpenAI-compatible `/v1/chat/completions` endpoint.
@Observable
@MainActor
final class VisionProxyService {

    /// Current provider and behavior settings. Persisted to UserDefaults.
    var config: ModelCatalog.VisionProxyConfiguration {
        didSet {
            if let encoded = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(encoded, forKey: "visionProxy.config")
            }
        }
    }

    private weak var engine: MLXInferenceEngine?
    private var pythonProcess: Process?
    private var isServerStarting = false

    init(engine: MLXInferenceEngine? = nil) {
        self.engine = engine
        if let data = UserDefaults.standard.data(forKey: "visionProxy.config"),
           let decoded = try? JSONDecoder().decode(ModelCatalog.VisionProxyConfiguration.self, from: data) {
            self.config = Self.migrate(decoded)
        } else {
            self.config = ModelCatalog.VisionProxyConfiguration()
        }
    }

    /// One-time migration: clear stale FastVLM-0.5B paths and redirect model paths
    /// from the old app-support models dir to the new `~/Ai-models/` root.
    private static func migrate(_ config: ModelCatalog.VisionProxyConfiguration) -> ModelCatalog.VisionProxyConfiguration {
        var config = config
        let oldScriptName = "fastvlm_server.py"
        if config.serverScriptPath.hasSuffix(oldScriptName) {
            config.serverScriptPath = VisionProxyServerScript.installedPath
        }
        if config.serverModelPath.contains("FastVLM-0.5B") {
            config.serverModelPath = VisionProxyServerScript.defaultModelPath
        }
        if config.inProcessModelPath.contains("FastVLM-0.5B") {
            config.inProcessModelPath = ModelCatalog.defaultVisionProxyModelPath
        }
        // Redirect any path still pointing to the old app-support models dir to ~/Ai-models/.
        let oldModelsDir = SwiftMaestroPaths.appSupportDir.appendingPathComponent("models").path
        let newRoot = ModelCatalog.modelsRoot
        if config.serverModelPath.hasPrefix(oldModelsDir) {
            config.serverModelPath = config.serverModelPath.replacingOccurrences(
                of: oldModelsDir,
                with: newRoot
            )
        }
        if config.inProcessModelPath.hasPrefix(oldModelsDir) {
            config.inProcessModelPath = config.inProcessModelPath.replacingOccurrences(
                of: oldModelsDir,
                with: newRoot
            )
        }
        return config
    }

    func setEngine(_ engine: MLXInferenceEngine) {
        self.engine = engine
    }

    // MARK: - Caption entry point

    /// Returns a text description of the image, or nil if the proxy is disabled or
    /// the provider cannot be reached. Throws only on unrecoverable failures.
    func caption(
        imageData: Data,
        prompt: String? = nil
    ) async throws -> String? {
        guard config.isEnabled else { return nil }
        let captionPrompt = prompt ?? config.captionPrompt

        if config.provider == .pythonServer {
            return try await captionWithPythonServer(imageData: imageData, prompt: captionPrompt)
        }

        // In-process path
        guard let engine else { throw VisionProxyError.engineUnavailable }
        guard let ciImage = CIImage(data: imageData) else {
            throw VisionProxyError.invalidImage
        }
        let proxyModel = buildProxyModel()
        let ocrText = await recognizeText(in: imageData)
        let augmentedPrompt = augmentPrompt(captionPrompt, withOCR: ocrText)
        return try await engine.captionWithFastVLM(
            proxyModel: proxyModel,
            image: .ciImage(ciImage),
            prompt: augmentedPrompt,
            maxTokens: config.maxCaptionTokens)
    }

    /// Convenience for `CIImage` sources (e.g., screenshots or pasted images).
    func caption(
        ciImage: CIImage,
        prompt: String? = nil
    ) async throws -> String? {
        guard config.isEnabled else { return nil }
        let captionPrompt = prompt ?? config.captionPrompt

        if config.provider == .pythonServer {
            // Render CIImage to PNG data for the HTTP server.
            guard let data = ciImage.toPNGData() else {
                throw VisionProxyError.invalidImage
            }
            return try await captionWithPythonServer(imageData: data, prompt: captionPrompt)
        }

        guard let engine else { throw VisionProxyError.engineUnavailable }
        let proxyModel = buildProxyModel()
        let ocrText = await recognizeText(in: ciImage.toPNGData() ?? Data())
        let augmentedPrompt = augmentPrompt(captionPrompt, withOCR: ocrText)
        return try await engine.captionWithFastVLM(
            proxyModel: proxyModel,
            image: .ciImage(ciImage),
            prompt: augmentedPrompt,
            maxTokens: config.maxCaptionTokens)
    }

    // MARK: - In-process model

    /// Build a loadable `MaestroModel` for the proxy from the configured path.
    /// Falls back to the standard model location if the configured path is missing.
    private func buildProxyModel() -> MaestroModel {
        let path = resolveModelPath()
        return MaestroModel(
            id: "vision-proxy-qwen3-vl",
            displayName: "Qwen3-VL 8B Vision Proxy",
            huggingFaceID: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
            isVision: true,
            localPath: path,
            estimatedMemoryGB: 6,
            isHidden: true)
    }

    /// Resolve the effective model path, checking the configured path and the
    /// standard SwiftMaestro model location.
    func resolveModelPath() -> String? {
        let candidates = [
            config.inProcessModelPath,
            ModelCatalog.defaultVisionProxyModelPath,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - Python Server

    /// True if the configured Python server is reachable at its health endpoint.
    var isPythonServerRunning: Bool {
        get async {
            let url = URL(string: "http://\(config.serverHost):\(config.serverPort)/health")!
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        }
    }

    /// Start the Python vision proxy server if it is not already running.
    func startPythonServer() async throws {
        guard config.provider == .pythonServer else { return }
        guard await !isPythonServerRunning else { return }
        guard !isServerStarting else { return }
        isServerStarting = true
        defer { isServerStarting = false }

        // Ensure the SwiftMaestro-managed Python venv and its dependencies exist
        // before trying to start the server.
        try await PythonVenvService.shared.ensureVisionDependencies()

        // Use the embedded server script if the configured path is missing.
        let scriptPath: String
        if FileManager.default.fileExists(atPath: config.serverScriptPath) {
            scriptPath = config.serverScriptPath
        } else {
            scriptPath = try VisionProxyServerScript.ensureInstalled()
        }

        let process = Process()
        // Use the SwiftMaestro-managed Python venv if available; otherwise fall back to the
        // system python3. The venv is created under ~/.ai-context/swiftmaestro/venv and holds
        // mlx_vlm + dependencies so public users don't need a global install.
        let venvPython = "\(NSHomeDirectory())/.ai-context/swiftmaestro/venv/bin/python"
        let useVenv = FileManager.default.fileExists(atPath: venvPython)
        if useVenv {
            process.executableURL = URL(fileURLWithPath: venvPython)
            process.arguments = [
                scriptPath,
                "--port", "\(config.serverPort)",
                "--host", config.serverHost,
                "--model-path", config.serverModelPath,
            ]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "python3", scriptPath,
                "--port", "\(config.serverPort)",
                "--host", config.serverHost,
                "--model-path", config.serverModelPath,
            ]
        }
        process.terminationHandler = { [weak self] task in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pythonProcess === task {
                    self.pythonProcess = nil
                }
            }
        }
        try process.run()
        pythonProcess = process

        // Wait for the /health endpoint to respond (up to 60 seconds).
        let deadline = Date(timeIntervalSinceNow: 60)
        while Date() < deadline {
            if await isPythonServerRunning { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        process.terminate()
        throw VisionProxyError.serverStartTimeout
    }

    /// Stop the Python server subprocess.
    func stopPythonServer() {
        if let process = pythonProcess, process.isRunning {
            process.terminate()
        }
        pythonProcess = nil
    }

    private func captionWithPythonServer(
        imageData: Data,
        prompt: String
    ) async throws -> String {
        try await startPythonServer()

        // Extract any readable text from the image using Apple's Vision framework.
        // This gives the VLM exact text (street signs, house numbers, labels) that
        // it often misreads or misses at the reduced resolution used for inference.
        let ocrText = await recognizeText(in: imageData)
        let augmentedPrompt: String
        if let ocrText, !ocrText.isEmpty {
            augmentedPrompt = "Text detected in the image by OCR:\n\(ocrText)\n\nUsing the image and the text above, \(prompt)"
        } else {
            augmentedPrompt = prompt
        }

        let base64 = imageData.base64EncodedString()
        let dataURI = "data:image/png;base64,\(base64)"
        let payload: [String: Any] = [
            "model": "vision-proxy",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": augmentedPrompt],
                        ["type": "image_url", "image_url": ["url": dataURI]]
                    ]
                ]
            ],
            "max_tokens": config.maxCaptionTokens,
            "temperature": 0.3
        ]

        let url = URL(string: "http://\(config.serverHost):\(config.serverPort)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload as Any)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VisionProxyError.serverRequestFailed
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw VisionProxyError.serverResponseInvalid
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Combine the user caption prompt with any OCR text found in the image.
    /// If no text was found, the original prompt is returned unchanged.
    private func augmentPrompt(_ prompt: String, withOCR ocrText: String?) -> String {
        guard let ocrText, !ocrText.isEmpty else { return prompt }
        return "Text detected in the image by OCR:\n\(ocrText)\n\nUsing the image and the text above, \(prompt)"
    }

    /// Use Apple's Vision framework to extract text from image data.
    /// Runs at the highest accuracy level and returns the recognized text lines
    /// joined by newlines, or nil if no text was found or decoding failed.
    private func recognizeText(in imageData: Data) async -> String? {
        guard let cgImage = CGImage.from(data: imageData) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        } catch {
            NSLog("[VisionProxy] OCR failed: \(error)")
            return nil
        }
    }
}

// MARK: - Errors

enum VisionProxyError: Error, LocalizedError {
    case engineUnavailable
    case invalidImage
    case serverScriptNotFound(String)
    case serverStartTimeout
    case serverRequestFailed
    case serverResponseInvalid

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            return "Vision proxy: inference engine is not available."
        case .invalidImage:
            return "Vision proxy: could not decode the image."
        case .serverScriptNotFound(let path):
            return "Vision proxy server script not found at \(path)."
        case .serverStartTimeout:
            return "Vision proxy server failed to start within 60 seconds."
        case .serverRequestFailed:
            return "Vision proxy server request failed."
        case .serverResponseInvalid:
            return "Vision proxy server returned an invalid response."
        }
    }
}

// MARK: - CIImage helper

private extension CIImage {
    /// Render this CIImage to PNG data.
    func toPNGData() -> Data? {
        let context = CIContext(options: nil)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgImage = context.createCGImage(self, from: self.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        guard let tiff = nsImage.tiffRepresentation else { return nil }
        let bitmap = NSBitmapImageRep(data: tiff)
        return bitmap?.representation(using: .png, properties: [:])
    }
}

// MARK: - CGImage helper

private extension CGImage {
    /// Decode image data into a CGImage for Vision processing.
    static func from(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
