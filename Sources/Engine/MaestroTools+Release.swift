import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Release Upload Tool

/// Native tool that uploads a SwiftMaestro release DMG to swiftmaestro.com.
///
/// This tool exists because delegated project agents cannot access the macOS
/// Keychain directly via shell. The app reads the SFTP password from the
/// Keychain item created by `upload-release.sh` and passes it to the script
/// through the `SM_SFTP_PASS` environment variable, so the agent never sees the
/// raw secret.
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
            "Upload a SwiftMaestro release DMG (or other release file) to swiftmaestro.com. "
            + "SFTP credentials are read automatically from SwiftMaestro secrets: "
            + "1984_SFTP_USER (username) and 1984_SFTP_PASSWORD (password). "
            + "You do NOT need to provide the password. Use this when the user asks you to "
            + "publish a release DMG to the website.",
            properties: [
                "dmg_path": [
                    "type": "string",
                    "description": "Absolute path to the DMG or release file to upload.",
                ],
                "script_path": [
                    "type": "string",
                    "description": "Optional absolute path to upload-release.sh. "
                    + "Defaults to ~/Documents/swiftmaestro-site/upload-release.sh.",
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

    // No host/user/path is hardcoded: the SFTP host and username come from
    // SwiftMaestro secrets (Keychain) or the environment, and the upload script
    // path is derived from the current user's home directory at runtime. This
    // keeps personal infrastructure details out of the source tree.
    private static let defaultUploadScript = NSHomeDirectory() + "/Documents/swiftmaestro-site/upload-release.sh"
    private static let sftpUserSecret = "1984_SFTP_USER"
    private static let sftpHostSecret = "1984_SFTP_HOST"
    private static let sftpPasswordSecret = "1984_SFTP_PASSWORD"
    private static let fallbackSftpPasswordSecret = "swiftmaestro-1984-sftp-password"
    private static let fallbackSftpProject = "woodsee-site"

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

        let scriptPath = (args.script_path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultUploadScript)
            .replacingOccurrences(of: "~", with: NSHomeDirectory())
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            return errorJSON("upload-release.sh not found: \(scriptPath)")
        }

        // Read the SFTP credentials from SwiftMaestro secrets. The login keychain must
        // be unlocked and the app must be authorized to access it; we never show a
        // keychain password dialog.
        guard KeychainService.isDefaultKeychainUnlocked() else {
            return errorJSON(
                "The login keychain is locked. Unlock it in Keychain Access so "
                + "upload_release can read the SFTP credentials."
            )
        }

        guard let sftpUser = SecretsStore.resolveValue(name: sftpUserSecret, currentProject: nil)
            ?? envValue("SM_SFTP_USER"), !sftpUser.isEmpty else {
            return errorJSON(
                "SFTP username not configured. Add the global secret '1984_SFTP_USER' "
                + "in Settings → Secrets (or set the SM_SFTP_USER environment variable)."
            )
        }
        guard let sftpHost = SecretsStore.resolveValue(name: sftpHostSecret, currentProject: nil)
            ?? envValue("SM_SFTP_HOST"), !sftpHost.isEmpty else {
            return errorJSON(
                "SFTP host not configured. Add the global secret '1984_SFTP_HOST' "
                + "in Settings → Secrets (or set the SM_SFTP_HOST environment variable)."
            )
        }

        let password: String
        if let globalPassword = SecretsStore.resolveValue(name: sftpPasswordSecret, currentProject: nil),
           !globalPassword.isEmpty {
            password = globalPassword
        } else if let projectPassword = SecretsStore.resolveValue(
            name: fallbackSftpPasswordSecret,
            currentProject: fallbackSftpProject
        ), !projectPassword.isEmpty {
            password = projectPassword
        } else {
            return errorJSON(
                "SFTP password not found. This usually means the login keychain is "
                + "locked or SwiftMaestro is not authorized to access it.\n"
                + "1. Unlock the login keychain in Keychain Access.\n"
                + "2. Add the password in Settings → Secrets as either:\n"
                + "   - Global secret '1984_SFTP_PASSWORD', or\n"
                + "   - Project 'woodsee-site' secret 'swiftmaestro-1984-sftp-password'."
            )
        }

        let dryRun = args.dry_run ?? false
        let command = dryRun
            ? "\(shellEscape(scriptPath)) --dry-run \(shellEscape(dmgPath))"
            : "\(shellEscape(scriptPath)) \(shellEscape(dmgPath))"

        var env = ProcessInfo.processInfo.environment
        env["SM_SFTP_PASS"] = password
        env["SM_SFTP_USER"] = sftpUser
        env["SM_SFTP_HOST"] = sftpHost
        env["SM_SFTP_PORT"] = env["SM_SFTP_PORT"] ?? "2222"

        let result = runUploadCommand(command, cwd: NSHomeDirectory(), env: env)

        let redactedStdout = redactSecrets(result.stdout, password: password)
        let redactedStderr = redactSecrets(result.stderr, password: password)

        let filename = (dmgPath as NSString).lastPathComponent
        let remoteURL = "https://swiftmaestro.com/download/\(filename)"
        // For a dry-run, success means the command executed and previewed the upload,
        // not that a file was transferred. Return true so the agent knows it can proceed.
        let success = result.success

        return encodeJSON(UploadReleaseResult(
            success: success,
            exit_code: result.exitCode,
            stdout: redactedStdout,
            stderr: redactedStderr,
            remote_url: success ? remoteURL : nil,
            message: success
                ? (dryRun ? "Dry run succeeded. File would be uploaded to \(remoteURL)." : "Upload complete. File will be available at \(remoteURL)")
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

        process.waitUntilExit()
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

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

    private static func redactSecrets(_ text: String, password: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: password, with: "«redacted»")
        // Also mask the password if it appears as a percent-encoded LFTP_PASSWORD value.
        if let percent = password.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) {
            output = output.replacingOccurrences(of: percent, with: "«redacted»")
        }
        return output
    }
}
