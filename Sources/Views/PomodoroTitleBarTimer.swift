import SwiftUI

// MARK: - Pomodoro Title-Bar Timer
//
// The Omarchy waybar clock, translated to SwiftMaestro's main-window title
// bar (ToolbarItem .principal, dead center):
//
//   • Always visible: state glyph + remaining time counting down ("⊙ 25:00"),
//     tinted per state (idle muted / focus accent / paused orange / break
//     green — Omarchy's waybar colors).
//   • Hover → tooltip with the Omarchy info line: "Focus · 25:00 · Running",
//     today's stats, and the click affordances.
//   • Left-click → the Pomodoro dashboard panel (Omarchy: "Left: dashboard").
//   • Right-click → controls menu (Omarchy: "Right: reset") — state-aware
//     start/pause/resume/skip/reset plus a jump to the panel.
//
// The store ticks every 0.5s, so this re-renders live with negligible cost.

struct PomodoroTitleBarTimer: View {
    let store: PomodoroStore
    /// Open/focus the Pomodoro workspace panel (wired to ContentView.openPanel).
    let onOpenPanel: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: store.menuBarIcon)
                .font(.caption)
            Text(store.titleBarText)
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(stateTint.opacity(0.16), in: .capsule)
        .foregroundStyle(stateTint)
        .contentShape(Rectangle())
        .onTapGesture { onOpenPanel() }
        .contextMenu { controlsMenu }
        .help(tooltip)
    }

    /// Omarchy waybar state colors, softened for the macOS title bar.
    private var stateTint: Color {
        switch store.phase {
        case .idle: return .secondary
        case .work: return store.isPaused ? .orange : .accentColor
        case .shortBreak, .longBreak: return .green
        }
    }

    /// Omarchy's hover line: "Focus · 25:00 · Running" + stats + affordances.
    private var tooltip: String {
        var lines = "\(store.phase.displayName) · \(store.titleBarText) · \(store.statusWord)"
        if !store.currentLabel.isEmpty { lines += "\nWorking on: \(store.currentLabel)" }
        lines += "\nToday: \(store.todayStats().line)"
        lines += "\nClick: dashboard · Right-click: controls"
        return lines
    }

    @ViewBuilder
    private var controlsMenu: some View {
        switch store.phase {
        case .idle:
            Button("Start \(store.workMinutes) min Focus") { store.startWork() }
            Button("Start \(store.shortBreakMinutes) min Break") { store.startBreak() }
        case .work:
            Button(store.isPaused ? "Resume" : "Pause") {
                store.isPaused ? store.resume() : store.pause()
            }
            Button("Skip to Break") { store.skipPhase() }
        case .shortBreak, .longBreak:
            Button("End Break — Start Focus") { store.skipPhase() }
        }
        if store.phase != .idle {
            Button("Reset", role: .destructive) { store.stop() }
        }
        Divider()
        Button("Open Pomodoro Panel…") { onOpenPanel() }
    }
}
