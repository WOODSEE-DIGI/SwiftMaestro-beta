import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - System Health tools (Omarchy-style AI IT support)
//
// Agent access to crash reports, console logs, and live system state — the
// backend behind the SystemHealthWatchService "Diagnose with Maestro" flow.
// All local: .ips parsing, `log show` via Process, SystemMemory + ps.

extension MaestroTools {

    static func registerSystemHealthTools() async {
        await ToolRegistry.shared.register([
            ToolDefinition(
                name: "list_crash_reports", spec: systemHealthToolSpecs[0],
                category: ToolCategory.system.rawValue,
                handler: { call in await listCrashReports(call) }),
            ToolDefinition(
                name: "read_crash_report", spec: systemHealthToolSpecs[1],
                category: ToolCategory.system.rawValue,
                handler: { call in await readCrashReport(call) }),
            ToolDefinition(
                name: "console_log", spec: systemHealthToolSpecs[2],
                category: ToolCategory.system.rawValue,
                handler: { call in await consoleLog(call) }),
            ToolDefinition(
                name: "system_health", spec: systemHealthToolSpecs[3],
                category: ToolCategory.system.rawValue,
                handler: { _ in await systemHealth() }),
            ToolDefinition(
                name: "diagnose_crash", spec: systemHealthToolSpecs[4],
                category: ToolCategory.system.rawValue,
                handler: { call in await diagnoseCrash(call) }),
            ToolDefinition(
                name: "self_healing_stats", spec: systemHealthToolSpecs[5],
                category: ToolCategory.system.rawValue,
                handler: { _ in await selfHealingStats() }),
            ToolDefinition(
                name: "self_healing_failures", spec: systemHealthToolSpecs[6],
                category: ToolCategory.system.rawValue,
                handler: { call in await selfHealingFailures(call) }),
        ])
    }

    // MARK: - Specs

    static var systemHealthToolSpecs: [ToolSpec] {
        [
            rawSpec("list_crash_reports",
                "List recent macOS crash/hang reports (.ips) with process, "
                + "time, exception/termination reason. Use to see what has "
                + "been crashing or hung lately.",
                properties: [
                    "process": ["type": "string", "description": "Filter by process name (substring, case-insensitive)."],
                    "since_minutes": ["type": "integer", "description": "Only reports from the last N minutes (default: all, max 20 reports)."],
                ],
                required: []),
            rawSpec("read_crash_report",
                "Read a parsed macOS crash report: exception, termination "
                + "reason, crashed-thread backtrace (top frames), app version. "
                + "Pass a report path (from list_crash_reports) or a process "
                + "name to get its latest report.",
                properties: [
                    "path": ["type": "string", "description": "Absolute path to a .ips report."],
                    "process": ["type": "string", "description": "Process name — uses its newest report."],
                ],
                required: []),
            rawSpec("console_log",
                "Read recent unified-log (Console) messages for a process via "
                + "'log show'. Returns the last ~120 lines, capped. Use after "
                + "a crash to see what the app logged before it died.",
                properties: [
                    "process": ["type": "string", "description": "Process name (exact match preferred)."],
                    "minutes": ["type": "integer", "description": "Look-back window in minutes (default 10, max 120)."],
                ],
                required: ["process"]),
            rawSpec("system_health",
                "Snapshot of current system state: memory pressure (wired/"
                + "active/cache/compressed/free), load average, top CPU "
                + "processes, disk free space, uptime. Use when the user "
                + "reports slowness, hangs, or failed installs.",
                properties: [:], required: []),
            rawSpec("diagnose_crash",
                "One-call crash triage bundle for a process: latest crash "
                + "report summary + recent console log excerpt + current "
                + "system health. Use this FIRST when diagnosing a crash, "
                + "then drill in with read_crash_report / console_log.",
                properties: [
                    "process": ["type": "string", "description": "Process name to diagnose."],
                ],
                required: ["process"]),
            rawSpec("self_healing_stats",
                "Report the ToolCallGuardian's self-healing activity: tool "
                + "failures by class, heal rate, and the learned per-model "
                + "quirk profiles that stop repeat failures before they happen. "
                + "Use when the user asks whether agents are having tool trouble.",
                properties: [:], required: []),
            rawSpec("self_healing_failures",
                "List the most recent tool call failures (newest first) with "
                + "tool, failure class, model, and whether the guardian healed "
                + "it. Use to inspect what's actually breaking.",
                properties: [
                    "limit": ["type": "integer", "description": "Max entries (default 15, max 50)."],
                ],
                required: []),
        ]
    }

    // MARK: - Args

    private struct ListArgs: Codable { let process: String?; let since_minutes: Int? }
    private struct ReadArgs: Codable { let path, process: String? }
    private struct LogArgs: Codable { let process: String?; let minutes: Int? }
    private struct DiagnoseArgs: Codable { let process: String? }

    // MARK: - Report enumeration

    private struct ReportFile {
        let name: String
        let path: String
        let modified: Date
        let summary: CrashSummary
    }

    private static func recentReports(processFilter: String?,
                                      sinceMinutes: Int?) -> [ReportFile] {
        let dir = SystemHealthWatchService.reportsDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var files: [ReportFile] = []
        let cutoff = sinceMinutes.map { Date().addingTimeInterval(-TimeInterval($0 * 60)) }
        for name in names where name.hasSuffix(".ips") {
            let path = dir + "/" + name
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = attrs?[.modificationDate] as? Date ?? .distantPast
            if let cutoff, modified < cutoff { continue }
            guard let summary = SystemHealthWatchService.parseReport(
                at: URL(fileURLWithPath: path)) else { continue }
            if let filter = processFilter?.lowercased(),
               !summary.process.lowercased().contains(filter) { continue }
            files.append(ReportFile(name: name, path: path, modified: modified, summary: summary))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    // MARK: - Handlers

    private static func listCrashReports(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: ListArgs.self)
        let since = args?.since_minutes
        let reports = recentReports(processFilter: args?.process ?? nil, sinceMinutes: since)
        guard !reports.isEmpty else { return "No crash reports found." }
        var out = "Recent crash reports (\(reports.count)):\n\n"
        for report in reports.prefix(20) {
            let s = report.summary
            let when = s.timestamp?.formatted(date: .abbreviated, time: .shortened) ?? "unknown time"
            out += "- **\(s.process)** — \(s.headline)\n  \(when)\n  Path: \(report.path)\n"
        }
        return out
    }

    private static func readCrashReport(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: ReadArgs.self) else {
            return "Error: invalid arguments."
        }
        var targetPath: String?
        if let path = args.path?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            targetPath = path
        } else if let process = args.process?.trimmingCharacters(in: .whitespaces), !process.isEmpty {
            targetPath = recentReports(processFilter: process, sinceMinutes: nil).first?.path
            if targetPath == nil { return "No crash reports found for '\(process)'." }
        } else {
            return "Error: provide path or process."
        }
        guard let path = targetPath,
              let s = SystemHealthWatchService.parseReport(at: URL(fileURLWithPath: path)) else {
            return "Error: could not parse report."
        }
        var out = "**\(s.process)** \(s.appVersion.map { "v\($0)" } ?? "")\n"
        out += "- Time: \(s.timestamp?.formatted() ?? "unknown")\n"
        if !s.exception.isEmpty { out += "- Exception: \(s.exception)\n" }
        if !s.termination.isEmpty { out += "- Termination: \(s.termination)\n" }
        if s.isWatchdog { out += "- **This was a HANG** (watchdog-killed for unresponsiveness)\n" }
        if !s.topFrames.isEmpty {
            out += "- Crashed thread (top frames):\n"
            for (i, frame) in s.topFrames.enumerated() { out += "  \(i). \(frame)\n" }
        }
        out += "- Report: \(path)\n"
        return out
    }

    private static func consoleLog(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: LogArgs.self),
              let process = args.process?.trimmingCharacters(in: .whitespaces),
              !process.isEmpty else {
            return "Error: process is required."
        }
        let minutes = min(args.minutes ?? 10, 120)
        // Sanitize: process names go inside a quoted predicate — strip quotes
        // and backslashes so predicate injection can't break the query.
        let safe = process.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        let output = runProcess("/usr/bin/log", arguments: [
            "show", "--last", "\(minutes)m", "--style", "compact",
            "--predicate", "process == \"\(safe)\"",
        ], timeoutSeconds: 30, maxBytes: 24_000)
        guard !output.isEmpty else {
            return "No console messages for '\(process)' in the last \(minutes) min."
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(120).joined(separator: "\n")
        return "Console messages for \(process) (last \(minutes)m, newest \(tail.components(separatedBy: "\n").count) lines):\n\n```\n\(tail)\n```"
    }

    private static func systemHealth() async -> String {
        var out = "**System health**\n\n"
        if let mem = SystemMemory.snapshot() {
            let gb = { (bytes: Int) in String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
            out += "Memory: \(gb(mem.totalBytes)) total — \(gb(mem.availableBytes)) available "
                + "(wired \(gb(mem.wiredBytes)), active \(gb(mem.usedBytes)), "
                + "compressed \(gb(mem.compressedBytes)), cache \(gb(mem.cacheBytes)))\n"
        }
        var loadavg = [Double](repeating: 0, count: 3)
        if getloadavg(&loadavg, 3) != -1 {
            out += String(format: "Load average: %.2f %.2f %.2f (%d cores)\n",
                          loadavg[0], loadavg[1], loadavg[2],
                          ProcessInfo.processInfo.processorCount)
        }
        let bootTime = Date(timeIntervalSince1970: ProcessInfo.processInfo.systemUptime > 0
                            ? Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
                            : 0)
        out += "Uptime: \(formatUptime(ProcessInfo.processInfo.systemUptime)) (since \(bootTime.formatted(date: .abbreviated, time: .shortened)))\n"
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let free = attrs[.systemFreeSize] as? Int64 {
            out += String(format: "Disk free on /: %.1f GB\n", Double(free) / 1_073_741_824)
        }
        let ps = runProcess("/bin/ps", arguments: [
            "-Ao", "pid,pcpu,pmem,comm", "-r",
        ], timeoutSeconds: 10, maxBytes: 8_000)
        let top = ps.split(separator: "\n").dropFirst().prefix(8)
        if !top.isEmpty {
            out += "\nTop processes by CPU:\n```\n" + top.joined(separator: "\n") + "\n```"
        }
        return out
    }

    private static func diagnoseCrash(_ call: ToolCall) async -> String {
        guard let args = decodeArgs(call, as: DiagnoseArgs.self),
              let process = args.process?.trimmingCharacters(in: .whitespaces),
              !process.isEmpty else {
            return "Error: process is required."
        }
        var out = "# Crash triage: \(process)\n\n"
        // 1. Latest crash report
        if let latest = recentReports(processFilter: process, sinceMinutes: nil).first {
            let s = latest.summary
            out += "## Latest crash report\n"
            out += "- \(s.headline)\n"
            out += "- Time: \(s.timestamp?.formatted() ?? "unknown")\n"
            if !s.topFrames.isEmpty {
                out += "- Top frames: \(s.topFrames.prefix(3).joined(separator: " → "))\n"
            }
            out += "- Report: \(latest.path)\n\n"
        } else {
            out += "## Latest crash report\nNo crash report on file for '\(process)'.\n\n"
        }
        // 2. Console excerpt
        let safe = process.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        let logs = runProcess("/usr/bin/log", arguments: [
            "show", "--last", "10m", "--style", "compact",
            "--predicate", "process == \"\(safe)\"",
        ], timeoutSeconds: 30, maxBytes: 12_000)
        if !logs.isEmpty {
            let tail = logs.split(separator: "\n").suffix(60).joined(separator: "\n")
            out += "## Console (last 10 min)\n```\n\(tail)\n```\n\n"
        }
        // 3. System health
        if let mem = SystemMemory.snapshot() {
            let gbAvail = Double(mem.availableBytes) / 1_073_741_824
            out += String(format: "## System health\nMemory available: %.1f GB; ", gbAvail)
        }
        var loadavg = [Double](repeating: 0, count: 3)
        if getloadavg(&loadavg, 3) != -1 {
            out += String(format: "load %.2f\n", loadavg[0])
        }
        return out
    }

    // MARK: - Helpers

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(Int(seconds) % 3_600 / 60)m"
    }

    /// Run a short-lived subprocess with a hard timeout and output cap.
    /// Distinct from the shell tool: no approval needed for these read-only
    /// diagnostics, and a hung `log show` can never wedge the agent.
    private static func runProcess(
        _ executable: String, arguments: [String],
        timeoutSeconds: Int, maxBytes: Int
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var data = Data()
        let handle = pipe.fileHandleForReading
        while process.isRunning, Date() < deadline, data.count < maxBytes {
            let chunk = handle.availableData
            if chunk.isEmpty { usleep(50_000); continue }
            data.append(chunk)
            if data.count >= maxBytes { process.terminate(); break }
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        // Drain whatever remains after exit.
        data.append(handle.readDataToEndOfFile())
        return String(data: data.prefix(maxBytes), encoding: .utf8) ?? ""
    }

    // MARK: - Self-healing (ToolCallGuardian) handlers

    private static func selfHealingStats() async -> String {
        await ToolCallGuardian.shared.statsSummary()
    }

    private struct FailuresArgs: Codable { let limit: Int? }

    private static func selfHealingFailures(_ call: ToolCall) async -> String {
        let args = decodeArgs(call, as: FailuresArgs.self)
        let limit = min(args?.limit ?? 15, 50)
        return await ToolCallGuardian.shared.recentFailuresText(limit: limit)
    }
}
