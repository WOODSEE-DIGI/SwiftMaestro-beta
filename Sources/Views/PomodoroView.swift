import SwiftUI

// MARK: - Pomodoro Panel
//
// The full-size surface for the timer (the menu-bar extra is the pomarchy-
// style compact one). Big countdown, phase pill, session label, controls,
// inline durations, and today's stats — all on the shared PomodoroStore.

struct PomodoroView: View {
    @State private var store = PomodoroStore.shared

    var body: some View {
        VStack(spacing: 18) {
            // Phase + label
            HStack(spacing: 8) {
                Label(store.phase.displayName, systemImage: store.phase.icon)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                if store.isPaused {
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Big countdown (panel counts DOWN — the focus contract), with
            // pomarchy's count-up elapsed as the secondary line.
            Text(PomodoroStore.formatted(store.remaining))
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.default, value: store.remaining)
            if store.phase != .idle {
                Text("elapsed \(PomodoroStore.formatted(store.elapsed))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Session label
            TextField("Working on…", text: $store.currentLabel)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .disabled(store.phase != .idle && store.phase != .work)

            // Controls (state-aware, same verbs as the menu bar)
            HStack(spacing: 10) {
                switch store.phase {
                case .idle:
                    Button { store.startWork() } label: {
                        Label("Start Focus", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { store.startBreak() } label: {
                        Label("Break", systemImage: "leaf.fill")
                    }
                case .work:
                    if store.isPaused {
                        Button { store.resume() } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button { store.pause() } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                    }
                    Button { store.skipPhase() } label: {
                        Label("Skip", systemImage: "forward.fill")
                    }
                    .help("End this focus block early and take the break")
                    Button { store.stop() } label: {
                        Label("Reset", systemImage: "stop.fill")
                    }
                    .foregroundStyle(.red)
                case .shortBreak, .longBreak:
                    Button { store.skipPhase() } label: {
                        Label("End Break", systemImage: "forward.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { store.stop() } label: {
                        Label("Reset", systemImage: "stop.fill")
                    }
                    .foregroundStyle(.red)
                }
            }
            .controlSize(.large)

            Divider()
                .frame(maxWidth: 320)

            // Inline durations (pomarchy's config, live-editable)
            HStack(spacing: 14) {
                DurationStepper(title: "Focus", value: $store.workMinutes, range: 1...240)
                DurationStepper(title: "Break", value: $store.shortBreakMinutes, range: 1...60)
                DurationStepper(title: "Long", value: $store.longBreakMinutes, range: 1...120)
                DurationStepper(title: "Every", value: $store.cyclesBeforeLongBreak, range: 2...8)
            }

            // Today's stats (pomarchy's prompt line)
            Text("Today: \(store.todayStats().line)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Compact labeled stepper for one duration.
private struct DurationStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Stepper(value: $value, in: range) {
                Text("\(value)")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 28)
            }
        }
    }
}
