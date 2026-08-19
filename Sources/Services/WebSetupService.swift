import Foundation

// MARK: - Web MCP Auto-Configuration
//
// On first launch, detects installed web tools (webclaw, firecrawl, crawlkit)
// and auto-enables them in the MCP server list so the agent can search the
// web immediately. Runs once per install (tracked via UserDefaults flag).
//
// The native web_search/fetch_url tools work without any MCP server — this
// service enhances the experience by also connecting heavier MCP servers
// when they're available.

enum WebSetupService {

    /// UserDefaults key tracking whether auto-setup has run.
    private static let setupCompleteKey = "webSetup.autoConfigComplete.v1"

    /// True when first-launch web-tool auto-configuration has not run yet.
    /// Cheap UserDefaults read — used by `SetupProgressService.plan()`.
    static var needsConfiguration: Bool {
        !UserDefaults.standard.bool(forKey: setupCompleteKey)
    }

    /// Run auto-configuration once on first launch. Safe to call multiple times.
    /// Performed on a background queue so filesystem / `which` checks do not block
    /// the main actor during startup.
    static func configureIfNeeded(progress: SetupReporter? = nil) async {
        guard !UserDefaults.standard.bool(forKey: setupCompleteKey) else { return }

        await progress?.begin(SetupStepID.webTools, detail: "Detecting web search tools…")

        let found = await Task.detached(priority: .utility) {
            (
                webclaw: (findBinary("webclaw-mcp") != nil || findBinary("webclaw") != nil),
                firecrawl: FileManager.default.fileExists(
                    atPath: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/firecrawl-mcp-server/dist/index.js"
                ) && (findBinary("docker") != nil || findBinary("colima") != nil),
                readWebsiteFast: FileManager.default.fileExists(
                    atPath: "\(NSHomeDirectory())/GitHub/AI-ML-Agents/mcp-read-website-fast/dist/serve-restart.js"
                )
            )
        }.value

        UserDefaults.standard.set(true, forKey: setupCompleteKey)

        var servers = SwiftMaestroSettingsStore.loadMCPServers()
        var changed = false

        if found.webclaw, enableServer(&servers, named: "webclaw") { changed = true }
        if found.firecrawl, enableServer(&servers, named: "firecrawl") { changed = true }
        if found.readWebsiteFast, enableServer(&servers, named: "read-website-fast") { changed = true }

        if changed {
            SwiftMaestroSettingsStore.saveMCPServers(servers)
            NSLog("[WebSetup] Auto-enabled web MCP servers based on detected tools")
        }

        await progress?.finish(SetupStepID.webTools, .done)
    }

    /// Force-enable a server by name (idempotent).
    @discardableResult
    private static func enableServer(_ servers: inout [MCPServerEntry], named name: String) -> Bool {
        guard let idx = servers.firstIndex(where: { $0.name == name }),
              !servers[idx].enabled else { return false }
        servers[idx].enabled = true
        return true
    }

    /// Find a binary in PATH. Returns its full path or nil.
    private static func findBinary(_ name: String) -> String? {
        let pathDirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.local/bin",
        ]
        let fm = FileManager.default
        for dir in pathDirs {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // Check via `which` as fallback
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = output, !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }
}
