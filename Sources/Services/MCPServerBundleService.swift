import Foundation

/// Describes a bundled MCP server that ships inside the SwiftMaestro app bundle
/// and is extracted to `~/Library/Application Support/SwiftMaestro/mcp-servers/`
/// on first launch.
struct MCPServerBundle: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let bundleType: BundleType
    /// Relative path inside `Resources/mcp-servers/` in the app bundle.
    let bundlePath: String
    /// Optional relative path to a shared runtime directory inside the bundled
    /// `Resources/mcp-servers/` folder (e.g. `.runtime/node`).
    let runtimeDir: String?
    /// Relative path to the executable inside the extracted server directory.
    let executable: String
    /// Arguments passed to the executable. May contain `{{SERVER_DIR}}` placeholder
    /// which is replaced with the extracted server directory.
    let args: [String]
    /// Additional environment variables for the server process.
    let env: [String: String]
    /// Working directory for the server process. Defaults to the extracted server
    /// directory. May contain `{{SERVER_DIR}}` placeholder.
    let workingDir: String?
    /// Command to run once after extraction to install dependencies (e.g. npm install).
    /// Relative paths are resolved against the extracted server directory.
    let installCommand: String?
    /// Timeout for the install command in seconds. Default 300.
    let installTimeout: Int?
    /// Whether this server is enabled by default after installation.
    let enabledByDefault: Bool
    /// Human-readable description shown in Settings.
    let notes: String?

    enum BundleType: String, Codable, Sendable {
        case node
        case python
        case binary
        case embeddedScript
    }

    /// Sentinel for bundled server paths used in MCPServerEntry.
    static func bundledServerDir(name: String) -> String {
        "\(NSHomeDirectory())/Library/Application Support/SwiftMaestro/mcp-servers/\(name)"
    }

    /// Sentinel for the shared runtime directory extracted to Application Support.
    static func bundledRuntimeDir(name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return "\(NSHomeDirectory())/Library/Application Support/SwiftMaestro/mcp-servers/\(name)"
    }

    /// Resolve the absolute executable path after extraction.
    func resolvedExecutable(in serverDir: String, runtimeDir: String?) -> String {
        let base = executable
            .replacingOccurrences(of: "{{SERVER_DIR}}", with: serverDir)
            .replacingOccurrences(of: "{{RUNTIME_DIR}}", with: runtimeDir ?? "")
        if base.hasPrefix("/") {
            return base
        }
        return "\(serverDir)/\(base)"
    }

    /// Resolve the working directory, defaulting to the extracted server directory.
    func resolvedWorkingDir(in serverDir: String) -> String {
        let base = workingDir?.replacingOccurrences(of: "{{SERVER_DIR}}", with: serverDir)
            ?? serverDir
        if base.hasPrefix("/") {
            return base
        }
        return "\(serverDir)/\(base)"
    }

    func resolvedArgs(in serverDir: String, runtimeDir: String?) -> [String] {
        args.map {
            $0.replacingOccurrences(of: "{{SERVER_DIR}}", with: serverDir)
              .replacingOccurrences(of: "{{RUNTIME_DIR}}", with: runtimeDir ?? "")
        }
    }

    func resolvedEnv(in serverDir: String, runtimeDir: String?) -> [String: String] {
        env.mapValues {
            $0.replacingOccurrences(of: "{{SERVER_DIR}}", with: serverDir)
              .replacingOccurrences(of: "{{RUNTIME_DIR}}", with: runtimeDir ?? "")
        }
    }
}

/// Manages the extraction and installation of bundled MCP servers from the app
/// bundle into the user's Application Support directory.
///
/// This is the foundation for a one-click install experience: every default MCP
/// server is either embedded directly in the app bundle or downloaded during
/// the build process, then extracted and prepared on first launch.
///
/// Deliberately NON-isolated (no @MainActor): first-run installation copies
/// bundles, runs npm install, and ad-hoc signs binaries — heavy synchronous
/// work that used to run on the main thread (via the app launch `.task`) and
/// beachball the app exactly while the welcome sheet was up. All state is
/// immutable after init or lives in UserDefaults, so the class is Sendable.
final class MCPServerBundleService: @unchecked Sendable {

    static let shared = MCPServerBundleService()

    /// UserDefaults key tracking whether the bundled servers have been extracted
    /// and installed for this app version.
    private static let installedVersionKey = "mcpServerBundle.installedVersion"
    /// Name of the manifest file inside the bundled `mcp-servers` directory.
    private static let manifestName = "mcp-server-manifest.json"

    private let fm = FileManager.default
    private let bundleServersURL: URL?
    private let supportServersURL: URL

    /// The currently installed bundle version, or nil if never installed.
    private var installedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.installedVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.installedVersionKey) }
    }

    init() {
        bundleServersURL = Bundle.main.url(forResource: "mcp-servers", withExtension: nil)
        let home = fm.homeDirectoryForCurrentUser
        supportServersURL = home
            .appendingPathComponent("Library/Application Support/SwiftMaestro/mcp-servers", isDirectory: true)
    }

    /// Returns true if a bundled server directory exists in the app bundle.
    var hasBundledServers: Bool {
        guard let bundleServersURL else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: bundleServersURL.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// True when this launch will actually install servers (bundle present and
    /// version changed). Cheap: reads the manifest JSON and one UserDefaults
    /// key. Used by `SetupProgressService.plan()` to decide whether the
    /// first-run setup sheet is needed at all.
    var needsInstall: Bool {
        guard hasBundledServers, let manifest = try? loadManifest() else { return false }
        return installedVersion != manifest.version
    }

    /// Extract and install all bundled MCP servers. Safe to call multiple times;
    /// re-runs only when the app bundle's server bundle version changes.
    ///
    /// - Parameter progress: optional reporter for the first-run setup sheet;
    ///   every extract / dependency-install / codesign item is named live so
    ///   the user can see exactly what is happening.
    /// - Returns: An array of installed server bundle descriptors.
    func installIfNeeded(progress: SetupReporter? = nil) async throws -> [MCPServerBundle] {
        guard hasBundledServers else {
            NSLog("[MCPServerBundle] No bundled servers found in app bundle")
            return []
        }

        let manifest = try loadManifest()
        let currentVersion = manifest.version

        if installedVersion == currentVersion {
            NSLog("[MCPServerBundle] Already at version %@, skipping extraction", currentVersion)
            return manifest.servers
        }

        NSLog("[MCPServerBundle] Installing bundled servers version %@", currentVersion)
        await progress?.begin(SetupStepID.mcpServers, detail: "Preparing components…")

        try fm.createDirectory(at: supportServersURL, withIntermediateDirectories: true)

        let relativeRuntimeDir = manifest.runtimeDir
        let runtimeDir = MCPServerBundle.bundledRuntimeDir(name: relativeRuntimeDir)
        var failedServers: [String] = []
        for server in manifest.servers {
            do {
                try await install(server: server, relativeRuntimeDir: relativeRuntimeDir, runtimeDir: runtimeDir, progress: progress)
            } catch {
                failedServers.append(server.id)
                NSLog("[MCPServerBundle] Server '%@' installation failed: %@", server.id, error.localizedDescription)
                await progress?.update(SetupStepID.mcpServers,
                                       detail: "\(server.name) failed — continuing with the rest")
            }
        }

        installedVersion = currentVersion
        if failedServers.isEmpty {
            NSLog("[MCPServerBundle] Installation complete")
            await progress?.finish(SetupStepID.mcpServers, .done,
                                   detail: "\(manifest.servers.count) tools installed")
        } else {
            NSLog("[MCPServerBundle] Installation complete with failures: %@", failedServers.joined(separator: ", "))
            await progress?.finish(SetupStepID.mcpServers,
                                   .failed("\(failedServers.count) of \(manifest.servers.count) failed"),
                                   detail: "Failed: \(failedServers.joined(separator: ", "))")
        }
        return manifest.servers
    }

    /// Force re-installation of all bundled servers, regardless of version.
    func reinstall(progress: SetupReporter? = nil) async throws -> [MCPServerBundle] {
        installedVersion = nil
        return try await installIfNeeded(progress: progress)
    }

    /// Returns the MCP server entries described by the bundled manifest, whether or
    /// not they have been extracted yet. This is the source for the "Bundled Preset".
    func bundledEntries() -> [MCPServerEntry] {
        guard let manifest = try? loadManifest() else { return [] }
        let runtimeDir = MCPServerBundle.bundledRuntimeDir(name: manifest.runtimeDir)
        return manifest.servers.map { entry(for: $0, runtimeDir: runtimeDir) }
    }

    /// Returns only the bundled entries whose executables are already present in the
    /// user's Application Support directory.
    func installedBundledEntries() -> [MCPServerEntry] {
        guard let manifest = try? loadManifest() else { return [] }
        let runtimeDir = MCPServerBundle.bundledRuntimeDir(name: manifest.runtimeDir)
        return manifest.servers.compactMap { resolvedEntry(for: $0, runtimeDir: runtimeDir) }
    }

    /// Returns a non-optional MCPServerEntry describing how this bundled server
    /// should be launched after extraction. Does not verify the executable exists;
    /// use this when building the bundled preset list.
    func entry(for server: MCPServerBundle, runtimeDir: String?) -> MCPServerEntry {
        let serverDir = MCPServerBundle.bundledServerDir(name: server.id)
        let executable = server.resolvedExecutable(in: serverDir, runtimeDir: runtimeDir)

        var entry = MCPServerEntry(
            name: server.name,
            command: executable,
            scriptPath: "",
            env: server.resolvedEnv(in: serverDir, runtimeDir: runtimeDir)
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n"),
            workingDir: server.resolvedWorkingDir(in: serverDir),
            timeout: 10,
            enabled: server.enabledByDefault,
            args: server.resolvedArgs(in: serverDir, runtimeDir: runtimeDir),
            notes: server.notes
        )
        entry.id = UUID()
        return entry
    }

    /// Returns the resolved MCPServerEntry for a bundled server if it has been
    /// installed, otherwise nil.
    func resolvedEntry(for server: MCPServerBundle, runtimeDir: String?) -> MCPServerEntry? {
        let serverDir = MCPServerBundle.bundledServerDir(name: server.id)
        let executable = server.resolvedExecutable(in: serverDir, runtimeDir: runtimeDir)
        guard fm.isExecutableFile(atPath: executable) else { return nil }

        var entry = MCPServerEntry(
            name: server.name,
            command: executable,
            scriptPath: "",
            env: server.resolvedEnv(in: serverDir, runtimeDir: runtimeDir)
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n"),
            workingDir: server.resolvedWorkingDir(in: serverDir),
            timeout: 10,
            enabled: server.enabledByDefault,
            args: server.resolvedArgs(in: serverDir, runtimeDir: runtimeDir),
            notes: server.notes
        )
        entry.id = UUID()
        return entry
    }

    /// If bundled servers are installed and the user has not already customized their
    /// MCP server list, replace the default entries with the resolved bundled entries.
    /// This lets a fresh install use the bundled servers without manual configuration.
    func applyBundledServersIfNeeded() async {
        guard hasBundledServers else { return }

        let current = SwiftMaestroSettingsStore.loadMCPServers()
        // If the user has already customized their server list (i.e. it does not exactly
        // match the hardcoded defaults), do not overwrite it.
        let defaults = MCPServerEntry.defaults
        let isDefaultList = current.count == defaults.count
            && current.allSatisfy { entry in
                defaults.contains { $0.name == entry.name
                    && $0.command == entry.command
                    && $0.workingDir == entry.workingDir }
            }

        guard isDefaultList else {
            NSLog("[MCPServerBundle] User has customized MCP servers; leaving list untouched")
            return
        }

        let manifest = try? loadManifest()
        guard let manifest else { return }
        let runtimeDir = MCPServerBundle.bundledRuntimeDir(name: manifest.runtimeDir)

        var updated: [MCPServerEntry] = []
        for defaultEntry in defaults {
            if let bundled = manifest.servers.first(where: { $0.name == defaultEntry.name }),
               let resolved = resolvedEntry(for: bundled, runtimeDir: runtimeDir) {
                updated.append(resolved)
            } else {
                updated.append(defaultEntry)
            }
        }

        SwiftMaestroSettingsStore.saveMCPServers(updated)
        NSLog("[MCPServerBundle] Applied %d bundled MCP server entries", updated.count)
    }

    // MARK: - Private

    private func loadManifest() throws -> MCPServerBundleManifest {
        guard let bundleServersURL else {
            throw BundleError.noBundledServers
        }
        let manifestURL = bundleServersURL.appendingPathComponent(Self.manifestName)
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(MCPServerBundleManifest.self, from: data)
    }

    private func install(server: MCPServerBundle, relativeRuntimeDir: String?, runtimeDir: String?, progress: SetupReporter?) async throws {
        guard let bundleServersURL else {
            throw BundleError.noBundledServers
        }

        let sourceURL = bundleServersURL.appendingPathComponent(server.bundlePath, isDirectory: true)
        let destinationURL = supportServersURL.appendingPathComponent(server.id, isDirectory: true)
        let serverDir = destinationURL.path

        // Remove any previous installation to ensure a clean state.
        try? fm.removeItem(at: destinationURL)
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        NSLog("[MCPServerBundle] Extracting %@ from %@", server.id, sourceURL.path)
        await progress?.update(SetupStepID.mcpServers, detail: "Extracting \(server.name)…")
        try fm.copyItem(at: sourceURL, to: destinationURL)

        // Make sure the executable is, in fact, executable.
        let executablePath = server.resolvedExecutable(in: serverDir, runtimeDir: runtimeDir)
        if fm.fileExists(atPath: executablePath) {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
        }

        // Extract the shared runtime directory once if one is defined.
        if let relativeRuntimeDir,
           !relativeRuntimeDir.isEmpty {
            let runtimeSourceURL = bundleServersURL.appendingPathComponent(relativeRuntimeDir, isDirectory: true)
            let runtimeDestinationURL = supportServersURL.appendingPathComponent(relativeRuntimeDir, isDirectory: true)
            let runtimeDestPath = runtimeDestinationURL.path
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: runtimeDestPath, isDirectory: &isDir) {
                NSLog("[MCPServerBundle] Extracting runtime %@", runtimeDestPath)
                try fm.copyItem(at: runtimeSourceURL, to: runtimeDestinationURL)
            }
        }

        // Run the install command if one is specified.
        if let installCommand = server.installCommand, !installCommand.isEmpty {
            await progress?.update(SetupStepID.mcpServers,
                                   detail: "Installing \(server.name) dependencies (this can take a few minutes)…")
            try await runInstallCommand(installCommand, in: serverDir, timeout: server.installTimeout ?? 300)
        }

        // Attempt to sign embedded binaries so they pass Hardened Runtime checks.
        // This is best-effort; if no signing identity is available it is skipped.
        try? await signEmbeddedBinaries(in: serverDir, label: server.name, progress: progress)
        if let runtimeDir {
            try? await signEmbeddedBinaries(in: runtimeDir, label: "shared runtime", progress: progress)
        }
    }

    private func runInstallCommand(_ command: String, in serverDir: String, timeout: Int) async throws {
        NSLog("[MCPServerBundle] Running install command for %@: %@", serverDir, command)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `currentDirectoryURL` already sets the working directory, so there is no
        // need to `cd` into a shell-quoted path. Avoiding the `cd` removes the
        // quoting bug for paths containing spaces (e.g. "Application Support").
        process.arguments = ["-lic", command]
        process.currentDirectoryURL = URL(fileURLWithPath: serverDir)
        process.environment = ProcessInfo.processInfo.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: errData, encoding: .utf8) ?? "unknown"
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    NSLog("[MCPServerBundle] Install succeeded: %@", out)
                    continuation.resume()
                } else {
                    NSLog("[MCPServerBundle] Install failed: %@", err)
                    continuation.resume(throwing: BundleError.installFailed(serverDir: serverDir, command: command, stderr: err))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Ad-hoc sign every Mach-O binary in the server directory so it passes
    /// Hardened Runtime checks. This is sufficient without a paid Developer ID
    /// cert; a proper Developer ID release re-signs these during packaging.
    ///
    /// Two performance notes vs. the original implementation:
    ///  1. Only actual Mach-O binaries are signed. The old loop spawned
    ///     `codesign` for EVERY executable-permission file — hundreds of shell
    ///     scripts in a node tree — one blocking process spawn each, on the
    ///     main thread. The magic-bytes check cuts that to the handful of
    ///     real binaries.
    ///  2. The whole loop now runs off the main thread (the class is no
    ///     longer @MainActor), with each file named live in the setup sheet.
    private func signEmbeddedBinaries(in serverDir: String, label: String, progress: SetupReporter?) async throws {
        let items = (try? fm.subpathsOfDirectory(atPath: serverDir)) ?? []
        var binaries: [String] = []
        for item in items {
            let path = "\(serverDir)/\(item)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard fm.isExecutableFile(atPath: path), isMachOBinary(at: path) else { continue }
            binaries.append(path)
        }
        guard !binaries.isEmpty else { return }

        for (index, path) in binaries.enumerated() {
            let name = URL(fileURLWithPath: path).lastPathComponent
            await progress?.update(SetupStepID.mcpServers,
                                   detail: "Signing \(label): \(name) (\(index + 1) of \(binaries.count))",
                                   progress: Double(index + 1) / Double(binaries.count))
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", "--timestamp=none", path]
            try? sign.run()
            sign.waitUntilExit()
        }
    }

    /// Reads the first four bytes of a file and matches them against the
    /// Mach-O magic numbers (32/64-bit, both endians, plus universal/fat).
    private func isMachOBinary(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        switch magic {
        case 0xFEEDFACE, 0xCEFAEDFE,   // MH_MAGIC / MH_CIGAM (32-bit)
             0xFEEDFACF, 0xCFFAEDFE,   // MH_MAGIC_64 / MH_CIGAM_64
             0xCAFEBABE, 0xBEBAFECA,   // FAT_MAGIC / FAT_CIGAM
             0xCAFEBABF, 0xBFBAFECA:   // FAT_MAGIC_64 / FAT_CIGAM_64
            return true
        default:
            return false
        }
    }

    enum BundleError: LocalizedError {
        case noBundledServers
        case installFailed(serverDir: String, command: String, stderr: String)

        var errorDescription: String? {
            switch self {
            case .noBundledServers:
                return "No bundled MCP servers found in the app bundle."
            case .installFailed(let serverDir, let command, let stderr):
                return "Failed to install bundled server at \(serverDir) with command '\(command)': \(stderr)"
            }
        }
    }
}

/// Top-level manifest describing the bundled MCP server bundle.
struct MCPServerBundleManifest: Codable, Sendable {
    let version: String
    let runtimeDir: String?
    let servers: [MCPServerBundle]
}

private extension String {
    /// Escapes the string for safe use inside a double-quoted shell string.
    var escapingForShell: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
}
