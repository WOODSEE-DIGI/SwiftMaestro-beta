import Foundation

/// Manages the SwiftMaestro-managed Python virtual environment.
///
/// The venv lives at `~/.ai-context/swiftmaestro/venv` and isolates the
/// dependencies required by the HuggingFace download helper and the vision
/// proxy server. Public users do not need a global Python install.
@MainActor
final class PythonVenvService {

    static let shared = PythonVenvService()

    /// Path to the venv python executable.
    let venvDir: URL
    let pythonExecutable: URL

    /// Set once `ensureVisionDependencies()` has actually run `pip install`
    /// successfully this app session, so repeated calls (e.g. one per model
    /// download click) don't re-run it every time. Concurrent `pip install`
    /// invocations against the SAME venv are a real corruption/race risk —
    /// this was found to be a contributing cause of one download's helper
    /// process behaving erratically when a second download was started into
    /// the same venv while the first was still using it.
    private var visionDependenciesEnsured = false
    /// Serializes concurrent callers so only one `pip install` for these
    /// packages ever runs at a time, and later callers await the same result
    /// instead of starting a redundant parallel install.
    private var visionDependenciesTask: Task<Void, Error>?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        venvDir = home.appendingPathComponent(".ai-context/swiftmaestro/venv", isDirectory: true)
        pythonExecutable = venvDir.appendingPathComponent("bin/python")
    }

    /// Returns true if the venv python executable exists.
    var isVenvInstalled: Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: pythonExecutable.path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: pythonExecutable.path)
    }

    /// Ensure the venv exists, creating it if necessary.
    ///
    /// - Returns: The path to the venv python executable.
    @discardableResult
    func ensureVenv() async throws -> String {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: pythonExecutable.path) {
            return pythonExecutable.path
        }

        try? fm.createDirectory(at: venvDir.deletingLastPathComponent(), withIntermediateDirectories: true)

        let systemPython = try await findSystemPython()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: systemPython)
        process.arguments = ["-m", "venv", venvDir.path]
        process.environment = ProcessInfo.processInfo.environment
        let stderr = Pipe()
        process.standardError = stderr

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: self.pythonExecutable.path)
                } else {
                    continuation.resume(throwing: VenvError.createFailed(stderr: err))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Ensure a set of Python packages is installed in the venv.
    ///
    /// Installs from the package names directly unless a specific version
    /// constraint is provided (e.g. "huggingface_hub>=0.26").
    func ensurePackages(_ packages: [String]) async throws {
        let python = try await ensureVenv()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-m", "pip", "install", "--upgrade"] + packages
        process.environment = ProcessInfo.processInfo.environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
                    continuation.resume(throwing: VenvError.packageInstallFailed(packages: packages, stderr: err))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Convenience: ensure the packages needed by the vision proxy server and the
    /// HuggingFace download helper are present.
    ///
    /// Idempotent per app session: the actual `pip install` only runs once;
    /// later calls (e.g. from a second model download started while the
    /// first is still in progress) await that same in-flight/completed
    /// result instead of launching a second concurrent `pip install` against
    /// the same venv.
    func ensureVisionDependencies() async throws {
        if visionDependenciesEnsured { return }
        if let existingTask = visionDependenciesTask {
            try await existingTask.value
            return
        }
        let task = Task {
            try await ensurePackages([
                "mlx_vlm",
                "flask",
                "pillow",
                "torch",
                "torchvision",
                "timm",
                "huggingface_hub",
                "hf-transfer",
            ])
        }
        visionDependenciesTask = task
        do {
            try await task.value
            visionDependenciesEnsured = true
            visionDependenciesTask = nil
        } catch {
            visionDependenciesTask = nil
            throw error
        }
    }

    /// Find a suitable system Python 3 interpreter.
    private func findSystemPython() async throws -> String {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        let fm = FileManager.default
        for candidate in candidates {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue else { continue }
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw VenvError.noPythonFound
    }

    enum VenvError: LocalizedError {
        case noPythonFound
        case createFailed(stderr: String)
        case packageInstallFailed(packages: [String], stderr: String)

        var errorDescription: String? {
            switch self {
            case .noPythonFound:
                return "Could not find a system Python 3 interpreter."
            case .createFailed(let stderr):
                return "Failed to create Python venv: \(stderr)"
            case .packageInstallFailed(let packages, let stderr):
                return "Failed to install Python packages \(packages.joined(separator: ", ")): \(stderr)"
            }
        }
    }
}
