import AppKit
import Foundation
import UserNotifications

// MARK: - System Health Watch Service
//
// The Omarchy-style "AI IT support" watcher: monitors the user's
// DiagnosticReports folder for new .ips crash files; on a new crash (or a
// watchdog termination = a hang the system killed), posts a notification —
// "Process crashed: X" — with actions "Diagnose with Maestro" (opens a chat
// pre-seeded with the crash context) and "Ignore This App" (permanent
// per-process mute). Re-notifies a process at most once per 30 minutes.
//
// No private APIs: DiagnosticReports is world-readable and the app is
// unsandboxed. The agent side (console/health/crash-report tools) lives in
// MaestroTools+SystemHealth.swift.

/// One parsed crash/hang report, distilled for the notification + agent.
struct CrashSummary: Sendable, Hashable {
    var process: String
    var appVersion: String?
    var timestamp: Date?
    /// e.g. "EXC_BAD_ACCESS (SIGSEGV)" — empty for clean terminations.
    var exception: String
    /// e.g. "Namespace WATCHDOG, code 0x8badf00d" (hang force-killed).
    var termination: String
    /// Top symbols of the crashed thread (up to 5), e.g. "UIKitCore · -[Foo bar]".
    var topFrames: [String]
    var path: String

    var isWatchdog: Bool {
        termination.localizedCaseInsensitiveContains("WATCHDOG")
            || termination.localizedCaseInsensitiveContains("0x8badf00d")
    }

    /// Notification body / chat-seed one-liner.
    var headline: String {
        let kind = isWatchdog ? "was killed for hanging" : "crashed"
        let reason = !exception.isEmpty ? exception : termination
        return reason.isEmpty ? "\(process) \(kind)" : "\(process) \(kind) — \(reason)"
    }
}

@Observable
@MainActor
final class SystemHealthWatchService: NSObject {

    static let shared = SystemHealthWatchService()

    // MARK: Settings (UserDefaults)

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
                 isEnabled ? startWatching() : stopWatching() }
    }
    private(set) var ignoredProcesses: Set<String> {
        didSet { UserDefaults.standard.set(Array(ignoredProcesses), forKey: Keys.ignored) }
    }

    private enum Keys {
        static let enabled = "systemHealthWatch.enabled"
        static let ignored = "systemHealthWatch.ignoredProcesses"
    }

    // MARK: State

    /// Set by the app at launch — opens the Navigator chat and seeds the
    /// diagnostic prompt. (Closure, not a direct dependency, so this service
    /// doesn't reach into ChatViewModel/engine wiring.)
    var onDiagnose: ((CrashSummary) -> Void)?

    private var watchSource: DispatchSourceFileSystemObject?
    private var knownReports: Set<String> = []
    private var lastNotified: [String: Date] = [:]
    /// Debounce: several .ips files can land within a second of each other.
    private var scanTask: Task<Void, Never>?

    private static let renotifyInterval: TimeInterval = 30 * 60

    nonisolated static let reportsDir = NSHomeDirectory()
        + "/Library/Logs/DiagnosticReports"

    private override init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        ignoredProcesses = Set(defaults.stringArray(forKey: Keys.ignored) ?? [])
        super.init()
    }

    /// Called once at app launch: registers the notification category/delegate
    /// and starts the folder watch.
    func start() {
        registerNotificationCategory()
        guard isEnabled else { return }
        startWatching()
    }

    // MARK: - Folder watch (DispatchSource VNODE — no polling)

    private func startWatching() {
        stopWatching()
        let fd = open(Self.reportsDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in self?.scheduleScan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchSource = source
        // Baseline: existing files are "known" (don't notify on old crashes).
        knownReports = currentReportNames()
    }

    private func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    private func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            self.scanForNewReports()
        }
    }

    private func currentReportNames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.reportsDir)) ?? []
        return Set(names.filter { $0.hasSuffix(".ips") })
    }

    private func scanForNewReports() {
        let current = currentReportNames()
        let new = current.subtracting(knownReports)
        knownReports = current
        for name in new {
            let url = URL(fileURLWithPath: Self.reportsDir + "/" + name)
            guard let summary = Self.parseReport(at: url) else { continue }
            handle(summary)
        }
    }

    // MARK: - Notification

    private func handle(_ summary: CrashSummary) {
        guard !ignoredProcesses.contains(summary.process) else { return }
        if let last = lastNotified[summary.process],
           Date().timeIntervalSince(last) < Self.renotifyInterval { return }
        lastNotified[summary.process] = Date()

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = summary.isWatchdog
            ? "Process hung: \(summary.process)"
            : "Process crashed: \(summary.process)"
        content.body = summary.headline
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["reportPath": summary.path, "process": summary.process]
        center.add(UNNotificationRequest(
            identifier: "crash-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func ignoreProcess(_ name: String) {
        ignoredProcesses.insert(name)
    }

    // MARK: - Notification plumbing

    static let categoryID = "com.woodseedigi.swiftmaestro.crashAlert"
    static let diagnoseActionID = "com.woodseedigi.swiftmaestro.diagnose"
    static let ignoreActionID = "com.woodseedigi.swiftmaestro.ignoreProcess"

    private func registerNotificationCategory() {
        let center = UNUserNotificationCenter.current()
        let diagnose = UNNotificationAction(
            identifier: Self.diagnoseActionID,
            title: "Diagnose with Maestro",
            options: [.foreground])
        let ignore = UNNotificationAction(
            identifier: Self.ignoreActionID,
            title: "Ignore This App",
            options: [.destructive])
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [diagnose, ignore],
            intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.delegate = SystemHealthNotificationDelegate.shared
    }

    // MARK: - IPS parsing (public for the agent tools)

    /// Parse an .ips file: line 1 is a JSON metadata header, the remainder is
    /// the crash payload JSON. Tolerant — missing keys yield empty fields.
    nonisolated static func parseReport(at url: URL) -> CrashSummary? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let firstNewline = text.firstIndex(of: "\n") else { return nil }
        let headerText = String(text[..<firstNewline])
        let payloadText = String(text[text.index(after: firstNewline)...])
        let header = (try? JSONSerialization.jsonObject(
            with: Data(headerText.utf8))) as? [String: Any] ?? [:]
        let payload = (try? JSONSerialization.jsonObject(
            with: Data(payloadText.utf8))) as? [String: Any] ?? [:]

        let process = (header["app_name"] as? String)
            ?? (payload["procName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let appVersion = header["app_version"] as? String
        let timestamp = (header["timestamp"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }

        let exceptionDict = payload["exception"] as? [String: Any] ?? [:]
        let exceptionType = exceptionDict["type"] as? String ?? ""
        let exceptionSignal = exceptionDict["signal"] as? String ?? ""
        let exception = [exceptionType, exceptionSignal]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let terminationDict = payload["termination"] as? [String: Any] ?? [:]
        var termination = terminationDict["namespace"] as? String ?? ""
        if let reasons = terminationDict["reasons"] as? [[String: Any]] {
            let codes = reasons.compactMap { $0["description"] as? String }
            if !codes.isEmpty {
                termination += (termination.isEmpty ? "" : " ") + codes.joined(separator: "; ")
            }
        }

        // Top frames of the faulting thread.
        var frames: [String] = []
        let threads = payload["threads"] as? [[String: Any]] ?? []
        let images = payload["usedImages"] as? [[String: Any]] ?? []
        let faulting = payload["faultingThread"] as? Int ?? 0
        if faulting < threads.count {
            let frameList = threads[faulting]["frames"] as? [[String: Any]] ?? []
            for frame in frameList.prefix(5) {
                if let symbol = frame["symbol"] as? String {
                    frames.append(symbol)
                } else if let idx = frame["imageIndex"] as? Int,
                          idx < images.count,
                          let name = images[idx]["name"] as? String {
                    let offset = frame["imageOffset"] as? Int ?? 0
                    frames.append("\(name) + \(offset)")
                }
            }
        }

        return CrashSummary(
            process: process, appVersion: appVersion, timestamp: timestamp,
            exception: exception, termination: termination,
            topFrames: frames, path: url.path)
    }
}

// MARK: - Chat seeding

extension SystemHealthWatchService {
    /// The prompt pre-seeded into the Navigator chat when the user picks
    /// "Diagnose with Maestro". Structured so the agent immediately reaches
    /// for the system-health tools instead of asking the user to paste logs.
    static func diagnosticPrompt(for summary: CrashSummary) -> String {
        var prompt = summary.isWatchdog
            ? "The app **\(summary.process)** was killed by the system for hanging (unresponsive)."
            : "The process **\(summary.process)** just crashed."
        if !summary.exception.isEmpty { prompt += "\nException: \(summary.exception)" }
        if !summary.termination.isEmpty { prompt += "\nTermination: \(summary.termination)" }
        if let version = summary.appVersion { prompt += "\nVersion: \(version)" }
        if let time = summary.timestamp {
            prompt += "\nTime: \(time.formatted(date: .abbreviated, time: .standard))"
        }
        if !summary.topFrames.isEmpty {
            prompt += "\nTop crashed-thread frames:\n"
                + summary.topFrames.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
        }
        prompt += "\nFull report: \(summary.path)\n\n"
        prompt += """
        Please diagnose this: use diagnose_crash for the bundled triage (report + \
        recent console logs + system health), drill in with read_crash_report and \
        console_log as needed, then explain the most likely cause in plain language \
        and suggest a concrete fix. If the fix is a safe command (restart an agent, \
        clear a cache, kill a stuck process), offer to run it before running it.
        """
        return prompt
    }
}

// MARK: - Notification delegate (file scope: UNUserNotificationCenterDelegate
// requires nonisolated methods, which a type nested in @MainActor can't satisfy)

final class SystemHealthNotificationDelegate: NSObject, @unchecked Sendable {
    static let shared = SystemHealthNotificationDelegate()
}

extension SystemHealthNotificationDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let process = info["process"] as? String ?? ""
        let path = info["reportPath"] as? String ?? ""
        let action = response.actionIdentifier
        Task { @MainActor in
            let service = SystemHealthWatchService.shared
            switch action {
            case SystemHealthWatchService.ignoreActionID:
                service.ignoreProcess(process)
            default:
                // Default tap or the Diagnose action both open the chat.
                let url = URL(fileURLWithPath: path)
                if let summary = SystemHealthWatchService.parseReport(at: url) {
                    service.onDiagnose?(summary)
                }
            }
        }
        completionHandler()
    }

    /// Show banners even while SwiftMaestro is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
