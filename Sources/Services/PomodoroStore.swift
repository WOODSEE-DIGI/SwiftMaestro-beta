import Foundation
import SwiftUI
import UserNotifications

// MARK: - Pomodoro Store
//
// Timer engine + state for the Pomodoro panel, the menu-bar extra, and the
// pomodoro_control agent tool. Follows the project-wide
// `@Observable @MainActor` store pattern.
//
// UX mirrors pomarchy (Omarchy's waybar pomodoro):
// - Menu bar shows elapsed work time counting UP (pomarchy's signature),
//   remaining time during breaks, nothing while idle. Per-state glyphs like
//   pomarchy's per-state icons/colors.
// - State-aware actions: start work / start break while idle, pause/resume
//   during work, stop & reset; "end break" during breaks. Breaks auto-start
//   when a focus block completes, with a notification to step away.
// - Durations changeable inline (persisted — pomarchy's config.toml role);
//   completed sessions append to a JSONL log powering "N done · Hh Mm focus"
//   stats (pomarchy's sessions.jsonl role).
//
// Timer is endDate-based, not tick-counted: remaining derives from Date()
// vs endDate, so sleep/app-nap can't drift the clock. The 0.5s Task loop
// only refreshes the UI and fires phase expiry.

@Observable
@MainActor
final class PomodoroStore {

    static let shared = PomodoroStore()

    enum Phase: String, Sendable {
        case idle, work, shortBreak, longBreak

        var displayName: String {
            switch self {
            case .idle: return "Idle"
            case .work: return "Focus"
            case .shortBreak: return "Break"
            case .longBreak: return "Long Break"
            }
        }

        /// pomarchy-style per-state glyphs.
        var icon: String {
            switch self {
            case .idle: return "timer"
            case .work: return "timer.circle.fill"
            case .shortBreak, .longBreak: return "leaf.fill"
            }
        }
    }

    // MARK: Published state

    private(set) var phase: Phase = .idle
    private(set) var isPaused = false
    /// Seconds remaining on the current phase (driven by endDate).
    private(set) var remaining: TimeInterval
    /// Total seconds configured for the current phase (elapsed = duration - remaining).
    private(set) var phaseDuration: TimeInterval
    /// Freeform label for what the current focus block is for.
    var currentLabel = ""

    /// Elapsed seconds in the current phase (pomarchy counts UP during work).
    var elapsed: TimeInterval {
        phase == .idle ? 0 : max(0, phaseDuration - remaining)
    }

    /// Menu-bar text: elapsed during work (count-up), remaining during
    /// breaks, empty while idle (pomarchy shows just the icon then).
    var menuBarText: String {
        switch phase {
        case .idle: return ""
        case .work: return Self.formatted(elapsed)
        case .shortBreak, .longBreak: return Self.formatted(remaining)
        }
    }

    /// Menu-bar glyph per state, paused included (pomarchy's per-state icons).
    var menuBarIcon: String {
        switch phase {
        case .idle: return "timer"
        case .work: return isPaused ? "pause.circle" : "timer.circle.fill"
        case .shortBreak, .longBreak: return "leaf.fill"
        }
    }

    // MARK: Settings (persisted — the config.toml equivalent)

    var workMinutes: Int {
        didSet { UserDefaults.standard.set(workMinutes, forKey: Keys.workMinutes) }
    }
    var shortBreakMinutes: Int {
        didSet { UserDefaults.standard.set(shortBreakMinutes, forKey: Keys.shortBreakMinutes) }
    }
    var longBreakMinutes: Int {
        didSet { UserDefaults.standard.set(longBreakMinutes, forKey: Keys.longBreakMinutes) }
    }
    var cyclesBeforeLongBreak: Int {
        didSet { UserDefaults.standard.set(cyclesBeforeLongBreak, forKey: Keys.cyclesBeforeLongBreak) }
    }

    private enum Keys {
        static let workMinutes = "pomodoro.workMinutes"
        static let shortBreakMinutes = "pomodoro.shortBreakMinutes"
        static let longBreakMinutes = "pomodoro.longBreakMinutes"
        static let cyclesBeforeLongBreak = "pomodoro.cyclesBeforeLongBreak"
    }

    // MARK: Internals

    private var endDate: Date?
    /// Remaining seconds captured at pause time (endDate unused while paused).
    private var pausedRemaining: TimeInterval = 0
    private var ticker: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        let work = defaults.object(forKey: Keys.workMinutes) as? Int ?? 25
        workMinutes = work
        shortBreakMinutes = defaults.object(forKey: Keys.shortBreakMinutes) as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: Keys.longBreakMinutes) as? Int ?? 15
        cyclesBeforeLongBreak = defaults.object(forKey: Keys.cyclesBeforeLongBreak) as? Int ?? 4
        remaining = TimeInterval(work * 60)
        phaseDuration = TimeInterval(work * 60)
    }

    // MARK: - Controls (pomarchy CLI parity)

    /// Start a focus block.
    func startWork(label: String? = nil, minutes: Int? = nil) {
        if let label { currentLabel = label }
        startPhase(.work, minutes: minutes ?? workMinutes)
    }

    /// Start a break directly (pomarchy's `break` command — skips the
    /// current focus block without completing it).
    func startBreak() {
        startPhase(.shortBreak, minutes: shortBreakMinutes)
    }

    func pause() {
        guard phase != .idle, !isPaused, let endDate else { return }
        pausedRemaining = max(0, endDate.timeIntervalSinceNow)
        isPaused = true
        self.endDate = nil
        ticker?.cancel()
        ticker = nil
        remaining = pausedRemaining
    }

    func resume() {
        guard isPaused, pausedRemaining > 0 else { return }
        isPaused = false
        endDate = Date().addingTimeInterval(pausedRemaining)
        startTicker()
    }

    /// pomarchy's right-click quick action: start / pause / resume / end break.
    func toggle() {
        switch phase {
        case .idle: startWork()
        case .work: isPaused ? resume() : pause()
        case .shortBreak, .longBreak: advancePhase(completedNaturally: false)
        }
    }

    /// Stop everything back to idle (configured work duration showing).
    func stop() {
        ticker?.cancel()
        ticker = nil
        endDate = nil
        isPaused = false
        phase = .idle
        currentLabel = ""
        remaining = TimeInterval(workMinutes * 60)
        phaseDuration = TimeInterval(workMinutes * 60)
    }

    /// pomarchy's restart: abandon current state, fresh work block from 0:00.
    func restart() {
        stop()
        startWork()
    }

    /// End the current phase immediately and advance (no completion credit).
    func skipPhase() {
        guard phase != .idle else { return }
        advancePhase(completedNaturally: false)
    }

    /// Status snapshot for the agent tool (pomarchy's `state` JSON role).
    var statusDescription: String {
        var parts = ["phase=\(phase.rawValue)",
                     "elapsed=\(Self.formatted(elapsed))",
                     "remaining=\(Self.formatted(remaining))",
                     "paused=\(isPaused)"]
        if !currentLabel.isEmpty { parts.append("label=\"\(currentLabel)\"") }
        let stats = todayStats()
        parts.append("today=\"\(stats.line)\"")
        return parts.joined(separator: ", ")
    }

    static func formatted(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Phase engine

    private func startPhase(_ newPhase: Phase, minutes: Int) {
        ticker?.cancel()
        phase = newPhase
        isPaused = false
        phaseDuration = TimeInterval(minutes * 60)
        endDate = Date().addingTimeInterval(phaseDuration)
        remaining = phaseDuration
        startTicker()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, let endDate = self.endDate else { return }
                let left = endDate.timeIntervalSinceNow
                if left <= 0 {
                    self.remaining = 0
                    self.advancePhase(completedNaturally: true)
                    return
                }
                self.remaining = left
            }
        }
    }

    /// Move to the next phase. A natural work completion logs the session
    /// (JSONL) and notifies; a natural break completion notifies and starts
    /// the next focus block (pomarchy: break auto-starts on work end, and
    /// the cycle continues).
    private func advancePhase(completedNaturally: Bool) {
        let finishedPhase = phase
        if completedNaturally, finishedPhase == .work {
            logCompletedWorkSession()
            postNotification(forFinished: finishedPhase)
        } else if completedNaturally {
            postNotification(forFinished: finishedPhase)
        }
        switch finishedPhase {
        case .work:
            let longDue = completedWorkCyclesToday() % max(1, cyclesBeforeLongBreak) == 0
            startPhase(longDue ? .longBreak : .shortBreak,
                       minutes: longDue ? longBreakMinutes : shortBreakMinutes)
        case .shortBreak, .longBreak:
            startPhase(.work, minutes: workMinutes)
        case .idle:
            break
        }
    }

    // MARK: - Notifications

    private func postNotification(forFinished finished: Phase) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        switch finished {
        case .work:
            content.title = "Focus block complete"
            content.body = currentLabel.isEmpty
                ? "Time for a break."
                : "\(currentLabel) — time for a break."
        case .shortBreak, .longBreak:
            content.title = "Break over"
            content.body = currentLabel.isEmpty
                ? "Back to focus."
                : "Back to: \(currentLabel)."
        case .idle:
            return
        }
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "pomodoro-\(UUID().uuidString)",
            content: content, trigger: nil))
    }

    // MARK: - Session log + today's stats (pomarchy's sessions.jsonl role)

    /// Append-only JSONL session log (one completed focus block per line).
    private var sessionsLogURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("SwiftMaestro", isDirectory: true)
            .appendingPathComponent("pomodoro-sessions.jsonl")
    }

    private func logCompletedWorkSession() {
        let record: [String: Any] = [
            "end": ISO8601DateFormatter().string(from: Date()),
            "workMinutes": phaseDuration / 60,
            "label": currentLabel,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = sessionsLogURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }

    struct TodayStats: Sendable {
        var sessions: Int
        var focusMinutes: Int
        /// pomarchy's stats-line: "4 done · 1h 40m focus"
        var line: String {
            let hours = focusMinutes / 60
            let mins = focusMinutes % 60
            let focus = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
            return "\(sessions) done · \(focus) focus"
        }
    }

    /// Completed work blocks today (from the JSONL log; date-compared by
    /// local day prefix, so no timezone math).
    func todayStats() -> TodayStats {
        guard let text = try? String(contentsOf: sessionsLogURL, encoding: .utf8) else {
            return TodayStats(sessions: 0, focusMinutes: 0)
        }
        let todayPrefix = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var sessions = 0
        var minutes = 0
        for line in text.split(separator: "\n") {
            guard line.contains("\"end\":\"\(todayPrefix)"),
                  let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            sessions += 1
            minutes += Int((record["workMinutes"] as? Double) ?? 0)
        }
        return TodayStats(sessions: sessions, focusMinutes: minutes)
    }

    /// Work cycles completed today — drives the long-break cadence
    /// (pomarchy-equivalent behavior; survives app relaunch via the log).
    private func completedWorkCyclesToday() -> Int {
        todayStats().sessions
    }
}
