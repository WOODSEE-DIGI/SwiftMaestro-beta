import SwiftUI

// MARK: - Pomodoro Menu Bar Extra
//
// The pomarchy pattern, translated from waybar+walker to the macOS menu bar:
// an icon + live counter always visible; left-click opens a state-aware menu
// (start/pause/resume/stop/end-break, today's stats, inline durations).

/// Menu-bar label: per-state glyph + pomarchy's count-up work counter
/// (breaks count down; idle shows just the icon).
struct PomodoroMenuBarLabel: View {
    let store: PomodoroStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.menuBarIcon)
            if !store.menuBarText.isEmpty {
                Text(store.menuBarText)
                    .monospacedDigit()
            }
        }
    }
}

/// The left-click menu. State-aware, regenerated on open — mirrors pomarchy's
/// walker menu: actions on top, stats line, inline duration steppers, and an
/// "Open Pomodoro Panel" escape hatch.
struct PomodoroMenuBarMenu: View {
    let store: PomodoroStore
    /// Open/focus the workspace Pomodoro panel (wired to App.openOrFocus).
    let onOpenPanel: () -> Void

    var body: some View {
        // State line, e.g. "Focus 12:34 / 25m — Quarterly report"
        if store.phase != .idle {
            Text(stateLine)
                .disabled(true)
        }

        // State-aware actions (pomarchy's menu items).
        switch store.phase {
        case .idle:
            Button("Start \(store.workMinutes) min focus") { store.startWork() }
            Button("Start \(store.shortBreakMinutes) min break") { store.startBreak() }
        case .work:
            if store.isPaused {
                Button("Resume") { store.resume() }
            } else {
                Button("Pause") { store.pause() }
            }
            Button("Stop & Reset") { store.stop() }
        case .shortBreak, .longBreak:
            Button("End Break — Start Focus") { store.skipPhase() }
            Button("Stop & Reset") { store.stop() }
        }

        Divider()

        // pomarchy's prompt line: "Pomodoro · 4 done · 1h 40m focus"
        Text("Pomodoro · \(store.todayStats().line)")
            .disabled(true)

        // Inline duration settings (pomarchy's "Set … duration" prompts).
        Stepper("Focus: \(store.workMinutes) min",
                value: Binding(
                    get: { store.workMinutes }, set: { store.workMinutes = $0 }),
                in: 1...240)
        Stepper("Break: \(store.shortBreakMinutes) min",
                value: Binding(
                    get: { store.shortBreakMinutes }, set: { store.shortBreakMinutes = $0 }),
                in: 1...60)
        Stepper("Long break: \(store.longBreakMinutes) min",
                value: Binding(
                    get: { store.longBreakMinutes }, set: { store.longBreakMinutes = $0 }),
                in: 1...120)
        Stepper("Long break every \(store.cyclesBeforeLongBreak)",
                value: Binding(
                    get: { store.cyclesBeforeLongBreak }, set: { store.cyclesBeforeLongBreak = $0 }),
                in: 2...8)

        Divider()

        Button("Open Pomodoro Panel…", action: onOpenPanel)
    }

    private var stateLine: String {
        let total = Int(store.phaseDuration / 60)
        var line = "\(store.phase.displayName) \(PomodoroStore.formatted(store.elapsed)) / \(total)m"
        if store.isPaused { line += " (paused)" }
        if !store.currentLabel.isEmpty { line += " — \(store.currentLabel)" }
        return line
    }
}
