import Foundation

/// Lifecycle and capability manager for running **Kimi K3 locally via Deltafin**.
///
/// Deltafin (https://github.com/gavamedia/deltafin) is the native Rust runtime
/// that streams K3's 2.8T-parameter MoE from NVMe on a single Mac — full,
/// unpruned, byte-exact weights. It exposes an OpenAI-compatible server; this
/// service owns health checks, process lifecycle, and the hardware-capability
/// verdict that drives the Settings UI.
///
/// Requirements for the full local corpus: Apple Silicon with ≥128 GB unified
/// memory (M1 Ultra or newer) and ~2 TB of free internal NVMe. Streaming mode
/// needs ~250 GB. Anything less and the model cannot be served at usable
/// speed — we surface that honestly instead of offering a broken model.
@MainActor @Observable
final class DeltafinK3Service {

    static let shared = DeltafinK3Service()

    // MARK: - Endpoint

    /// Loopback port for the local Deltafin server. Chosen to avoid collisions
    /// with LM Studio (1234), the vision proxy (8766/8767) and ad-hoc dev
    /// servers (8000/8080).
    static let defaultPort: Int = 8641
    static var baseURL: String { "http://127.0.0.1:\(defaultPort)" }
    static var chatCompletionsURL: URL? { URL(string: "\(baseURL)/v1/chat/completions") }
    static var modelsURL: URL? { URL(string: "\(baseURL)/v1/models") }

    /// The model identifier Deltafin's server advertises in /v1/models.
    static let servedModelID = "deltafin-kimi-k3"

    // MARK: - Requirements

    /// 128 GB unified memory = 137.4e9 bytes; accept ≥120e9 to absorb the
    /// OS-reported figure's variance. This is the M1 Ultra 128 GB floor.
    static let requiredRAMBytes: UInt64 = 120_000_000_000
    /// Full corpus: 1.7 TB experts + spines + sidecars, with headroom.
    static let recommendedDiskBytes: UInt64 = 2_000_000_000_000
    /// Streaming mode floor (resident spine + growing expert cache).
    static let streamDiskBytes: UInt64 = 250_000_000_000

    // MARK: - State

    enum ServerState: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var serverState: ServerState = .stopped
    /// Non-nil only for a server process this service spawned. A pre-existing
    /// server on the port is adopted (health passes) without being owned.
    private var serverProcess: Process?

    struct Capability {
        let ramBytes: UInt64
        let meetsRAM: Bool
        let modelRoot: String
        let diskFreeBytes: UInt64
        let meetsDiskFull: Bool
        let meetsDiskStream: Bool
        let binaryPath: String?
        let modelLooksInstalled: Bool

        var isReady: Bool {
            meetsRAM && binaryPath != nil && (meetsDiskFull || modelLooksInstalled)
        }
    }

    // MARK: - Capability probe

    func capability() -> Capability {
        let ram = ProcessInfo.processInfo.physicalMemory
        let root = Self.modelRoot
        let free = Self.freeBytes(atPath: root)
        let binary = Self.resolveBinaryPath()
        return Capability(
            ramBytes: ram,
            meetsRAM: ram >= Self.requiredRAMBytes,
            modelRoot: root,
            diskFreeBytes: free,
            meetsDiskFull: free >= Self.recommendedDiskBytes,
            meetsDiskStream: free >= Self.streamDiskBytes,
            binaryPath: binary,
            modelLooksInstalled: Self.modelLooksInstalled(at: root)
        )
    }

    static var modelRoot: String {
        let override = UserDefaults.standard.string(forKey: "deltafin.modelRoot") ?? ""
        if !override.isEmpty { return override }
        return NSHomeDirectory() + "/K3"
    }

    static func resolveBinaryPath() -> String? {
        if let override = UserDefaults.standard.string(forKey: "deltafin.binaryPath"),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            home + "/GitHub/AI-ML-Agents/deltafin/target/release/deltafin",
            home + "/GitHub/deltafin/target/release/deltafin",
            home + "/deltafin/target/release/deltafin",
            "/usr/local/bin/deltafin",
            "/opt/homebrew/bin/deltafin",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func freeBytes(atPath path: String) -> UInt64 {
        // Probe the deepest existing ancestor so a not-yet-created model root
        // still reports its volume's free space.
        var probe = path
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe) {
            let parent = (probe as NSString).deletingLastPathComponent
            if parent == probe { return 0 }
            probe = parent
        }
        guard let attrs = try? fm.attributesOfFileSystem(forPath: probe),
              let free = attrs[.systemFreeSize] as? NSNumber else { return 0 }
        return free.uint64Value
    }

    /// Cheap install marker: Deltafin writes `k3-meta/` beside the model.
    static func modelLooksInstalled(at root: String) -> Bool {
        FileManager.default.fileExists(atPath: root + "/k3-meta")
    }

    // MARK: - Health

    /// True when an OpenAI-compatible server answers /v1/models on our port.
    func health() async -> Bool {
        guard let url = Self.modelsURL else { return false }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Lifecycle

    /// Bring up the server if needed. Adopts a healthy foreign server on the
    /// port; otherwise spawns `deltafin serve` and polls health. K3 bootstrap
    /// (residency admission, spine mapping) can take minutes on a cold start,
    /// so the poll window is deliberately long.
    func ensureRunning() async throws {
        if await health() {
            serverState = .running
            return
        }
        let cap = capability()
        guard let binary = cap.binaryPath else {
            serverState = .failed("deltafin binary not found")
            throw DeltafinK3Error.binaryNotFound
        }
        guard cap.meetsRAM else {
            serverState = .failed("requires ≥128 GB unified memory")
            throw DeltafinK3Error.insufficientRAM
        }

        serverState = .starting

        let logDir = NSHomeDirectory()
            + "/Library/Application Support/SwiftMaestro/logs"
        try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        let logURL = URL(fileURLWithPath: logDir + "/deltafin.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "serve", "--host", "127.0.0.1", "--port", String(Self.defaultPort),
            "--model-root", Self.modelRoot,
        ]
        // Pass through an allowlisted set of Deltafin tuning variables when the
        // user has configured them in UserDefaults (Settings → Kimi K3).
        var environment = ProcessInfo.processInfo.environment
        for key in ["K3_SPINE", "K3_EXPERT_PIN_GB", "K3_EXPERT_PIN_PRIME",
                    "K3_EXPERT_READ_THREADS", "K3_EXPERT_STREAM_NOCACHE",
                    "K3_DSPARK", "K3_PILOT_GATE"] {
            if let value = UserDefaults.standard.string(forKey: "deltafin.env.\(key)"),
               !value.isEmpty {
                environment[key] = value
            }
        }
        process.environment = environment
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self, self.serverProcess == proc else { return }
                self.serverProcess = nil
                if case .starting = self.serverState {
                    self.serverState = .failed("exited during startup (code \(proc.terminationStatus))")
                } else {
                    self.serverState = .stopped
                }
            }
        }

        do {
            try process.run()
            serverProcess = process
        } catch {
            serverState = .failed(error.localizedDescription)
            throw DeltafinK3Error.launchFailed(error.localizedDescription)
        }

        // Poll health for up to 10 minutes while K3 boots.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            if await health() {
                serverState = .running
                return
            }
            if serverProcess == nil { break } // terminated during startup
        }
        if serverProcess != nil {
            serverState = .failed("server did not become healthy within 10 minutes")
            throw DeltafinK3Error.startupTimeout
        }
    }

    /// Stop a server we spawned. Adopted foreign servers are left running.
    func stop() {
        serverProcess?.terminate()
        serverProcess = nil
        serverState = .stopped
    }
}

enum DeltafinK3Error: LocalizedError {
    case binaryNotFound
    case insufficientRAM
    case launchFailed(String)
    case startupTimeout

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Deltafin binary not found. Build it (cargo build --release) and set the path in Settings → Kimi K3."
        case .insufficientRAM:
            return "Kimi K3 local requires a Mac with at least 128 GB unified memory (M1 Ultra or newer)."
        case .launchFailed(let detail):
            return "Could not launch Deltafin: \(detail)"
        case .startupTimeout:
            return "Deltafin did not become healthy within 10 minutes. See deltafin.log for details."
        }
    }
}
