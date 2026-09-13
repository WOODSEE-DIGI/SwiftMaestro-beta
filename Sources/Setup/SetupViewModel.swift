import Foundation
import Observation

@MainActor
@Observable
final class SetupViewModel {

    enum Phase: Equatable {
        case loading
        case ready
        case downloading
        case paused
        case verifying
        case verified
        case installing
        case installed
        case onlineModelSetup
        case failed(String)
    }

    /// Which payload the user wants. Custom lets them point at any .pkg
    /// plus an optional SHA-256 (auto-fetched from a `.sha256` sidecar when
    /// omitted).
    enum PayloadSelection: Equatable {
        case full
        case light
        case custom(url: String, sha256: String)
    }

    // MARK: - State

    private(set) var phase: Phase = .loading
    private(set) var manifest: PayloadManifest?
    var selection: PayloadSelection = .full
    var keepPayload = true
    var errorMessage: String?

    /// System profile used to recommend Full vs Light.
    struct SystemProfile: Equatable {
        let totalRAMBytes: Int64
        let freeDiskBytes: Int64
    }
    private(set) var profile: SystemProfile?
    private(set) var recommendation: PayloadSelection = .full
    private(set) var recommendationReason: String = ""

    let downloader = ResumableDownloader()
    private(set) var verifyProgress: Double = 0
    private(set) var installProgress: Double = 0
    private(set) var installMessage: String = "Installing SwiftMaestro…"
    private(set) var installStartTime: Date?
    private(set) var installHasReceivedFraction: Bool = false
    private(set) var installLogLines: [String] = []

    private var resumeState: ResumeState?
    private var activeDestination: URL?
    private var activePayloadInfo: PayloadManifest.Payload?

    enum LocalPayloadStatus: Equatable {
        case none
        case partial(bytes: Int64, expected: Int64)
        case complete(bytes: Int64, expected: Int64)
    }
    private(set) var localPayloadStatus: LocalPayloadStatus = .none

    // MARK: - Lifespan

    func load() async {
        phase = .loading
        do {
            manifest = try await ManifestLoader.fetch()
        } catch {
            // Baked-in fallback keeps the installer functional offline.
            manifest = ManifestLoader.fallback
            errorMessage = "Could not reach swiftmaestro.com — using embedded release info. \(error.localizedDescription)"
        }
        profile = Self.systemProfile()
        if let manifest {
            recommendation = Self.recommendation(for: profile, manifest: manifest)
            selection = recommendation
            recommendationReason = Self.recommendationReason(for: profile, selection: recommendation, manifest: manifest)
        }
        resumeState = ResumeState.load()
        await refreshLocalPayloadStatus()
        phase = .ready
    }

    /// Re-evaluates whether a partial or complete payload file already exists
    /// for the current selection. Call this after selection changes or on load.
    func refreshLocalPayloadStatus() async {
        guard let (info, destination) = await activePayload() else {
            localPayloadStatus = .none
            return
        }
        activeDestination = destination
        activePayloadInfo = info
        let size = Self.fileSize(destination)
        if size <= 0 {
            localPayloadStatus = .none
        } else if size >= info.sizeBytes {
            localPayloadStatus = .complete(bytes: size, expected: info.sizeBytes)
        } else {
            localPayloadStatus = .partial(bytes: size, expected: info.sizeBytes)
        }
    }

    /// Delete any existing partial or complete payload for the current
    /// selection so the next download starts from scratch.
    func discardLocalPayload() {
        guard let destination = activeDestination else { return }
        try? FileManager.default.removeItem(at: destination)
        if resumeState?.destinationPath == destination.path {
            ResumeState.clear()
            resumeState = nil
        }
        localPayloadStatus = .none
    }

    /// Advance to the verification/install step using the payload already on
    /// disk. Called from the ready screen when a complete file exists.
    func useLocalPayload() async {
        guard case .complete = localPayloadStatus, activeDestination != nil else { return }
        verifyProgress = 1.0
        phase = .verified
    }

    // MARK: - Download

    var hasResumablePartial: Bool {
        guard let state = resumeState else { return false }
        let partial = Self.fileSize(URL(fileURLWithPath: state.destinationPath))
        return partial > 0 && partial < state.expectedBytes
    }

    func startDownload() async {
        guard let payload = await activePayload() else {
            phase = .failed("No payload selected.")
            return
        }
        let (info, destination) = payload

        // Sanity: enough free space for the payload plus headroom.
        if let available = Self.availableBytes(onVolumeContaining: destination),
           available < info.sizeBytes + 1_073_741_824 {
            phase = .failed("Not enough free disk space. Need \(ByteFormatter.string(info.sizeBytes)) on the destination volume.")
            return
        }

        activeDestination = destination
        activePayloadInfo = info
        resumeState = ResumeState(
            payloadKey: selectionDescription,
            url: info.url.absoluteString,
            destinationPath: destination.path,
            expectedBytes: info.sizeBytes,
            sha256: info.sha256
        )
        resumeState?.save()

        phase = .downloading
        do {
            try await downloader.download(url: info.url, to: destination, expected: info.sizeBytes)
            await verify(destination: destination, expectedSHA256: info.sha256)
        } catch is CancellationError {
            phase = .paused
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func pauseDownload() {
        downloader.pause()
        if let destination = activeDestination {
            resumeState?.downloadedBytes = Self.fileSize(destination)
            resumeState?.save()
        }
    }

    func resumeDownload() async {
        guard let state = resumeState else {
            phase = .ready
            return
        }
        guard let url = URL(string: state.url) else {
            phase = .failed("Stored download URL is invalid: \(state.url)")
            return
        }
        let destination = URL(fileURLWithPath: state.destinationPath)

        if let manifest {
            switch state.payloadKey {
            case "full": activePayloadInfo = manifest.full
            case "light": activePayloadInfo = manifest.light
            default: activePayloadInfo = nil
            }
        }

        phase = .downloading
        do {
            try await downloader.download(url: url, to: destination, expected: state.expectedBytes)
            await verify(destination: destination, expectedSHA256: state.sha256)
        } catch is CancellationError {
            phase = .paused
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func verify(destination: URL, expectedSHA256: String) async {
        phase = .verifying
        verifyProgress = 0
        do {
            let actual = try await IntegrityVerifier.sha256Hex(of: destination) { [weak self] progress in
                Task { @MainActor in
                    self?.verifyProgress = progress
                }
            }
            guard actual.lowercased() == expectedSHA256.lowercased() else {
                // Corrupted payload — remove it so a retry starts clean.
                try? FileManager.default.removeItem(at: destination)
                phase = .failed("""
                    Integrity check failed.
                    Expected SHA-256: \(expectedSHA256)
                    Got:              \(actual)
                    The partial file was deleted. Please download again.
                    """)
                return
            }
            phase = .verified
        } catch {
            phase = .failed("Verification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Install

    func install() async {
        guard let destination = activeDestination else {
            phase = .failed("Missing downloaded package.")
            return
        }
        phase = .installing
        installProgress = 0
        installHasReceivedFraction = false
        installLogLines.removeAll(keepingCapacity: true)
        installStartTime = Date()
        if let info = activePayloadInfo, info.sizeBytes > 0 {
            installMessage = "Installing SwiftMaestro — writing \(ByteFormatter.string(info.sizeBytes)) to disk…"
        } else {
            installMessage = "Installing SwiftMaestro — this can take several minutes…"
        }
        do {
            try await InstallManager.installPackage(
                at: destination.path,
                onProgress: { [weak self] update in
                    Task { @MainActor in
                        if let fraction = update.fraction {
                            self?.installProgress = fraction
                            self?.installHasReceivedFraction = true
                        }
                        if let message = update.message {
                            self?.installMessage = message
                        }
                        if let line = update.rawLine {
                            self?.appendInstallLogLine(line)
                        }
                    }
                },
                onLogLine: { [weak self] line in
                    Task { @MainActor in
                        self?.appendInstallLogLine(line)
                    }
                }
            )
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        if !keepPayload {
            try? FileManager.default.removeItem(at: destination)
        }
        ResumeState.clear()
        resumeState = nil
        activeDestination = nil
        activePayloadInfo = nil
        phase = .installed
    }

    private func appendInstallLogLine(_ line: String) {
        installLogLines.append(line)
        if installLogLines.count > 500 {
            installLogLines.removeFirst(installLogLines.count - 500)
        }
    }

    // MARK: - Recovery

    /// Used by the error screen's "Try Again": resume a partial download when
    /// one exists, otherwise start the currently selected payload fresh.
    func retry() async {
        if resumeState.map({ partialExists($0) }) == true {
            await resumeDownload()
        } else {
            await startDownload()
        }
    }

    func dismissError() {
        phase = .ready
        errorMessage = nil
    }

    func showOnlineModelSetup() {
        phase = .onlineModelSetup
    }

    func finishOnlineModelSetup() {
        phase = .installed
    }

    private func partialExists(_ state: ResumeState) -> Bool {
        let size = Self.fileSize(URL(fileURLWithPath: state.destinationPath))
        return size > 0 && size < state.expectedBytes
    }

    // MARK: - Helpers

    private func activePayload() async -> (PayloadManifest.Payload, URL)? {
        let manifest = manifest ?? ManifestLoader.fallback
        let info: PayloadManifest.Payload
        switch selection {
        case .full:
            info = manifest.full
        case .light:
            info = manifest.light
        case .custom(let urlString, let sha256):
            guard let url = URL(string: urlString), !urlString.isEmpty else {
                phase = .failed("Enter a valid package URL.")
                return nil
            }
            let trimmed = sha256.trimmingCharacters(in: .whitespacesAndNewlines)
            let infoValue = PayloadManifest.Payload(
                url: url,
                sizeBytes: await Self.remoteSizeOrZero(url: url),
                sha256: trimmed,
                displayName: "Custom",
                summary: "Custom package"
            )
            return (infoValue, Self.defaultDestination(for: url))
        }

        let fileName = info.url.lastPathComponent
        return (info, Self.defaultDestination(for: info.url, fileName: fileName))
    }

    private static func defaultDestination(for url: URL, fileName: String? = nil) -> URL {
        let dir = SetupPaths.applicationSupport.appendingPathComponent("payloads", isDirectory: true)
        let name = fileName ?? url.lastPathComponent
        return dir.appendingPathComponent(name)
    }

    /// Content-Length of a remote file without downloading it (best effort;
    /// 0 when unknown — download progress then shows bytes without a total).
    private static func remoteSizeOrZero(url: URL) async -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let length = http.value(forHTTPHeaderField: "Content-Length"),
              let value = Int64(length) else { return 0 }
        return value
    }

    private var selectionDescription: String {
        switch selection {
        case .full: return "full"
        case .light: return "light"
        case .custom: return "custom"
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    private static func availableBytes(onVolumeContaining url: URL) -> Int64? {
        // Ensure the directory exists; resourceValues on a missing path can misreport 0.
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        // Try the modern "important usage" capacity first, then fall back to the
        // standard available capacity. Some volumes/keys report 0 or nil when the
        // URL doesn't exist or the key isn't supported.
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return capacity
        }
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity, capacity > 0 {
            return Int64(capacity)
        }
        return nil
    }

    // MARK: - Recommendation

    private static func systemProfile() -> SystemProfile {
        let ram = Int64(ProcessInfo.processInfo.physicalMemory)
        // Use the actual Application Support directory for the volume check so
        // the path exists and the capacity key returns a real value.
        let free = availableBytes(onVolumeContaining: SetupPaths.applicationSupport) ?? 0
        return SystemProfile(totalRAMBytes: ram, freeDiskBytes: free)
    }

    private static func recommendation(for profile: SystemProfile?, manifest: PayloadManifest) -> PayloadSelection {
        guard let profile else { return .light }
        let ramGB = Double(profile.totalRAMBytes) / 1_073_741_824
        let freeGB = Double(profile.freeDiskBytes) / 1_073_741_824
        let fullNeedsGB = Double(manifest.full.sizeBytes) / 1_073_741_824 + 5
        let lightNeedsGB = Double(manifest.light.sizeBytes) / 1_073_741_824 + 2

        if ramGB >= 32 && freeGB >= fullNeedsGB {
            return .full
        } else if freeGB >= lightNeedsGB {
            return .light
        } else {
            // Not enough disk for either — default to Light but warn in the UI.
            return .light
        }
    }

    private static func recommendationReason(for profile: SystemProfile?, selection: PayloadSelection, manifest: PayloadManifest) -> String {
        guard let profile else { return "Could not read system info." }
        let ramGB = Int(round(Double(profile.totalRAMBytes) / 1_073_741_824))
        let freeGB = Int(round(Double(profile.freeDiskBytes) / 1_073_741_824))
        let fullNeedsGB = Int(round(Double(manifest.full.sizeBytes) / 1_073_741_824 + 5))
        let lightNeedsGB = Int(round(Double(manifest.light.sizeBytes) / 1_073_741_824 + 2))

        switch selection {
        case .full:
            return "This Mac has \(ramGB) GB memory and \(freeGB) GB free disk space, so the Full installer is recommended."
        case .light:
            if Double(profile.totalRAMBytes) / 1_073_741_824 < 32 {
                return "This Mac has \(ramGB) GB memory. The Light installer is recommended; you can add an online or local model source after installing."
            } else if Double(profile.freeDiskBytes) / 1_073_741_824 < Double(manifest.full.sizeBytes) / 1_073_741_824 + 5 {
                return "This Mac has only \(freeGB) GB free disk space (Full needs about \(fullNeedsGB) GB). The Light installer is recommended."
            } else {
                return "This Mac has \(ramGB) GB memory and \(freeGB) GB free disk space. Light needs about \(lightNeedsGB) GB."
            }
        default:
            return ""
        }
    }
}

/// Nonisolated paths so plain types like `ResumeState` can reference them.
enum SetupPaths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SwiftMaestroSetup", isDirectory: true)
    }
}

// MARK: - Resume state persistence

struct ResumeState: Codable {
    var payloadKey: String
    var url: String
    var destinationPath: String
    var expectedBytes: Int64
    var sha256: String
    var downloadedBytes: Int64?

    static let stateURL = SetupPaths.applicationSupport.appendingPathComponent("state.json")

    static func load() -> ResumeState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(ResumeState.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(
            at: Self.stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: stateURL)
    }
}

// MARK: - Formatting

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}