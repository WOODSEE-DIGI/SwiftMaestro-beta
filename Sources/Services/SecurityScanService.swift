import Foundation

// MARK: - Security Scan Service
//
// Performs a local, on-Mac security review of a user-selected file before it
// is attached to a diagnostic report. Nothing leaves the machine until the
// scan finishes and the user reviews the redacted payload.
//
// Scans performed:
//   • Gatekeeper assessment (spctl --assess -vv)
//   • Quarantine / download-source xattrs
//   • File type / MIME sniffing (file -Ib)
//   • Optional ClamAV scan if `clamscan` is installed
//   • Basic executable entitlement check for Mach-O binaries

struct SecurityScanResult: Codable, Sendable {
    var passed: Bool
    var gatekeeper: GatekeeperResult
    var quarantine: QuarantineResult
    var fileType: String
    var clamAV: ClamAVResult
    var entitlements: EntitlementsResult
    var recommendations: [String]
    var scannedAt: Date

    struct GatekeeperResult: Codable, Sendable {
        var status: String
        var source: String?
        var accepted: Bool
    }

    struct QuarantineResult: Codable, Sendable {
        var isQuarantined: Bool
        var values: [String: String]
    }

    struct ClamAVResult: Codable, Sendable {
        var available: Bool
        var clean: Bool
        var output: String
    }

    struct EntitlementsResult: Codable, Sendable {
        var isExecutable: Bool
        var hasHardenedRuntime: Bool?
        var hasLibraryValidation: Bool?
        var output: String
    }
}

actor SecurityScanService {
    static let shared = SecurityScanService()

    private init() {}

    /// Run the full security scan on a file at the given path.
    func scanFile(at path: String) async -> SecurityScanResult {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let fileExists = FileManager.default.fileExists(atPath: url.path)

        let gatekeeper = await gatekeeperScan(url)
        let quarantine = quarantineScan(url)
        let fileType = fileTypeScan(url)
        let clamAV = await clamAVScan(url)
        let entitlements = entitlementsScan(url)

        var recommendations: [String] = []
        if !fileExists {
            recommendations.append("File could not be found at the given path.")
        }
        if quarantine.isQuarantined {
            recommendations.append("File is quarantined (downloaded from the internet). Remove the quarantine flag or use a system-generated screenshot if possible.")
        }
        if !gatekeeper.accepted {
            recommendations.append("Gatekeeper rejected or could not assess the file. Avoid attaching unsigned executables.")
        }
        if clamAV.available && !clamAV.clean {
            recommendations.append("ClamAV detected something in this file. Do not attach it.")
        }
        if entitlements.isExecutable && !(entitlements.hasHardenedRuntime ?? false) {
            recommendations.append("Attached binary does not declare the Hardened Runtime. Be cautious.")
        }

        let passed = fileExists
            && gatekeeper.accepted
            && !quarantine.isQuarantined
            && (!clamAV.available || clamAV.clean)

        return SecurityScanResult(
            passed: passed,
            gatekeeper: gatekeeper,
            quarantine: quarantine,
            fileType: fileType,
            clamAV: clamAV,
            entitlements: entitlements,
            recommendations: recommendations,
            scannedAt: Date()
        )
    }

    // MARK: - Gatekeeper

    private func gatekeeperScan(_ url: URL) async -> SecurityScanResult.GatekeeperResult {
        let (status, stdout, _) = runProcess(
            "/usr/bin/spctl",
            arguments: ["--assess", "-vv", url.path],
            timeoutSeconds: 15
        )
        // spctl returns 0 for accepted, non-zero for rejected/missing signature.
        let accepted = status == 0
        var source: String?
        for line in stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("source=") {
                source = String(trimmed.dropFirst("source=".count))
            } else if trimmed.hasPrefix("origin=") {
                // origin is fine too; fall back if no source.
                if source == nil { source = String(trimmed.dropFirst("origin=".count)) }
            }
        }
        let statusText = accepted ? "accepted" : (stdout.isEmpty ? "rejected/unsigned" : stdout.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\n", with: "; "))
        return SecurityScanResult.GatekeeperResult(status: statusText, source: source, accepted: accepted)
    }

    // MARK: - Quarantine xattrs

    private func quarantineScan(_ url: URL) -> SecurityScanResult.QuarantineResult {
        var values: [String: String] = [:]
        var isQuarantined = false
        let keys = [
            "com.apple.quarantine",
            "com.apple.metadata:kMDItemWhereFroms",
            "com.apple.metadata:kMDItemDownloadedDate",
        ]
        for key in keys {
            let (status, stdout, _) = runProcess(
                "/usr/bin/xattr",
                arguments: ["-p", key, url.path],
                timeoutSeconds: 5
            )
            if status == 0, !stdout.isEmpty {
                values[key] = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "com.apple.quarantine" { isQuarantined = true }
            }
        }
        return SecurityScanResult.QuarantineResult(isQuarantined: isQuarantined, values: values)
    }

    // MARK: - File type

    private func fileTypeScan(_ url: URL) -> String {
        let (_, stdout, _) = runProcess(
            "/usr/bin/file",
            arguments: ["-Ib", url.path],
            timeoutSeconds: 5
        )
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ClamAV

    private func clamAVScan(_ url: URL) async -> SecurityScanResult.ClamAVResult {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/clamscan")
                || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/clamscan") else {
            return SecurityScanResult.ClamAVResult(available: false, clean: true, output: "clamscan not installed")
        }
        let executable = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/clamscan")
            ? "/opt/homebrew/bin/clamscan"
            : "/usr/local/bin/clamscan"
        let (status, stdout, stderr) = runProcess(
            executable,
            arguments: ["--no-summary", url.path],
            timeoutSeconds: 60
        )
        let output = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = status == 0 && !output.localizedCaseInsensitiveContains("FOUND")
        return SecurityScanResult.ClamAVResult(available: true, clean: clean, output: output)
    }

    // MARK: - Executable entitlements

    private func entitlementsScan(_ url: URL) -> SecurityScanResult.EntitlementsResult {
        let fileType = fileTypeScan(url)
        let isExecutable = fileType.contains("application/x-mach-binary")
            || fileType.contains("application/x-executable")
            || fileType.contains("x-shellscript")

        guard isExecutable else {
            return SecurityScanResult.EntitlementsResult(
                isExecutable: false,
                hasHardenedRuntime: nil,
                hasLibraryValidation: nil,
                output: ""
            )
        }

        let (status, stdout, _) = runProcess(
            "/usr/bin/codesign",
            arguments: ["-d", "--entitlements", "-", "--xml", url.path],
            timeoutSeconds: 10
        )
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHardenedRuntime = output.localizedCaseInsensitiveContains("com.apple.security.cs.allow-jit")
            || output.localizedCaseInsensitiveContains("com.apple.security.cs.disable-library-validation")
            || output.localizedCaseInsensitiveContains("com.apple.security.automation.apple-events")
            || output.localizedCaseInsensitiveContains("<key>com.apple.security.app-sandbox</key>")
        let hasLibraryValidation = output.localizedCaseInsensitiveContains("com.apple.security.cs.disable-library-validation")
        return SecurityScanResult.EntitlementsResult(
            isExecutable: true,
            hasHardenedRuntime: hasHardenedRuntime,
            hasLibraryValidation: hasLibraryValidation,
            output: status == 0 ? output : "codesign failed"
        )
    }

    // MARK: - Process runner

    private nonisolated func runProcess(
        _ executable: String,
        arguments: [String],
        timeoutSeconds: Int
    ) -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch { return (-1, "", error.localizedDescription) }

        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, out, err)
    }
}
