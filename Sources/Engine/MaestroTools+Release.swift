import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Release Upload Tool

/// Native tool that uploads a SwiftMaestro release DMG to Onidel Object Storage
/// (Sydney) via the website repo's upload-to-onidel.sh.
///
/// Since the release pipeline moved off SFTP (2026-08), no credentials pass
/// through this tool: the script uses the MinIO `mc` client's locally
/// configured `onidel` alias. The agent never sees any secret.
extension MaestroTools {

    static func registerReleaseTools() async {
        await ToolRegistry.shared.register(
            ToolDefinition(
                name: "upload_release",
                spec: uploadReleaseToolSpec,
                category: ToolCategory.shell.rawValue,
                handler: { call in await uploadRelease(call) }
            )
        )
    }

    static var uploadReleaseToolSpec: ToolSpec {
        rawSpec(
            "upload_release",
            "Upload a SwiftMaestro release DMG (or appcast.xml) to Onidel Object Storage. "
            + "Files become publicly available at the swiftmaestro-releases bucket URL, which is "
            + "also where the Sparkle appcast and website download links point. "
            + "No credentials are needed — the upload script uses the local MinIO 'onidel' alias. "
            + "Use this when the user asks you to publish a release.",
            properties: [
                "dmg_path": [
                    "type": "string",
                    "description": "Absolute path to the DMG or release file to upload. "
                        + "A file named appcast.xml is uploaded as the Sparkle appcast.",
                ],
                "script_path": [
                    "type": "string",
                    "description": "Optional absolute path to upload-to-onidel.sh. "
                    + "Defaults to the swiftmaestro-site repo's upload-to-onidel.sh.",
                ],
                "dry_run": [
                    "type": "boolean",
                    "description": "If true, run the script with --dry-run to preview the upload without performing it.",
                ],
            ],
            required: ["dmg_path"]
        )
    }

    private struct UploadReleaseArgs: Decodable {
        let dmg_path: String?
        let script_path: String?
        let dry_run: Bool?

        enum CodingKeys: String, CodingKey {
            case dmg_path, script_path, dry_run
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dmg_path = try c.decodeIfPresent(String.self, forKey: .dmg_path)
            script_path = try c.decodeIfPresent(String.self, forKey: .script_path)
            let b = try? c.decodeIfPresent(LenientBool.self, forKey: .dry_run)
            dry_run = b?.value
        }
    }

    private struct UploadReleaseResult: Encodable {
        let success: Bool
        let exit_code: Int32
        let stdout: String
        let stderr: String
        let remote_url: String?
        let message: String
    }

    // The upload script lives in the (separate) swiftmaestro-site repo. No
    // host/user/path is hardcoded: the path is derived from the current user's
    // home directory at runtime and can be overridden per call or via env.
    private static let defaultUploadScript = NSHomeDirectory() + "/GitHub/FUSV/Websites/swiftmaestro-site/upload-to-onidel.sh"

    /// Public base URL of the Onidel bucket the script uploads to.
    private static let publicBaseURL = "https://s3.ap-southeast-2.onidel.cloud/swiftmaestro-releases"

    static func uploadRelease(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: UploadReleaseArgs.self),
              let rawPath = args.dmg_path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return errorJSON("upload_release requires a non-empty 'dmg_path'.")
        }

        let dmgPath = (rawPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dmgPath) else {
            return errorJSON("DMG not found: \(dmgPath)")
        }

        let scriptPath = (args.script_path?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? envValue("SM_UPLOAD_SCRIPT")
            ?? defaultUploadScript)
            .replacingOccurrences(of: "~", with: NSHomeDirectory())
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            return errorJSON(
                "upload-to-onidel.sh not found: \(scriptPath)\n"
                + "Pass script_path, set SM_UPLOAD_SCRIPT, or clone the swiftmaestro-site repo."
            )
        }

        let dryRun = args.dry_run ?? false
        let filename = (dmgPath as NSString).lastPathComponent
        // appcast.xml goes to the bucket root as the Sparkle feed.
        let isAppcast = filename == "appcast.xml"

        var command = shellEscape(scriptPath)
        if dryRun { command += " --dry-run" }
        if isAppcast { command += " --appcast" }
        command += " \(shellEscape(dmgPath))"

        let result = runUploadCommand(command, cwd: NSHomeDirectory(), env: ProcessInfo.processInfo.environment)

        let remoteURL = "\(publicBaseURL)/\(filename)"
        // For a dry-run, success means the command executed and previewed the upload,
        // not that a file was transferred. Return true so the agent knows it can proceed.
        let success = result.success

        return encodeJSON(UploadReleaseResult(
            success: success,
            exit_code: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            remote_url: success ? remoteURL : nil,
            message: success
                ? (dryRun ? "Dry run succeeded. File would be uploaded to \(remoteURL)." : "Upload complete. File is available at \(remoteURL)")
                : "Upload failed."
        ))
    }

    private static func envValue(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return value?.isEmpty == false ? value : nil
    }

    private static func runUploadCommand(
        _ command: String,
        cwd: String,
        env: [String: String]
    ) -> ShellRawResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = env
        if FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        let start = Date()
        do {
            try process.run()
        } catch {
            return ShellRawResult(
                success: false,
                exitCode: -1,
                stdout: "",
                stderr: "Failed to launch upload command: \(error.localizedDescription)",
                durationMs: 0,
                timedOut: false
            )
        }

        // Drain both pipes WHILE the process runs — reading only after
        // waitUntilExit deadlocks once the child fills the 64 KB pipe buffer
        // (mc prints progress continuously during a multi-GB upload).
        final class DataBox: @unchecked Sendable {
            private let lock = NSLock()
            var data = Data()
            func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
            func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let outBox = DataBox(), errBox = DataBox()
        stdoutPipe.fileHandleForReading.readabilityHandler = { outBox.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { errBox.append($0.availableData) }

        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        outBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        errBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        let stdout = String(data: outBox.snapshot(), encoding: .utf8) ?? ""
        let stderr = String(data: errBox.snapshot(), encoding: .utf8) ?? ""

        return ShellRawResult(
            success: process.terminationStatus == 0,
            exitCode: Int32(process.terminationStatus),
            stdout: stdout,
            stderr: stderr,
            durationMs: elapsedMs,
            timedOut: false
        )
    }

    /// Escape a string for safe use inside a single zsh argument.
    private static func shellEscape(_ value: String) -> String {
        // Replace single quotes with '"'"'"' to close, escape, and reopen the quote.
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
