import SwiftUI

// MARK: - Pomodoro Title-Bar Timer
//
// The Omarchy waybar clock, translated to SwiftMaestro's main-window title
// bar (ToolbarItem .principal, dead center):
//
//   • Always visible: state glyph + remaining time counting down ("⊙ 25:00"),
//     tinted per state (idle muted / focus accent / paused orange / break
//     green — Omarchy's waybar colors). Capsule highlight on hover, waybar-
//     minimal otherwise.
//   • Hover → tooltip with the Omarchy info line: "Focus · 25:00 · Running",
//     today's stats, and the click affordances.
//   • Left-click → the Omarchy dashboard as a DROPDOWN POPOVER beneath the
//     clock: phase header, "working on" field, circular countdown ring,
//     FOCUS CYCLE dots, phase tabs, start/pause/reset/skip controls, today's
//     stats, and a gear revealing inline duration steppers (pomarchy's
//     config.toml role). The workspace panel remains as an escape hatch.
//   • Right-click → state-aware controls menu (start/pause/resume/skip/reset).
//
// The store ticks every 0.5s, so this re-renders live with negligible cost.

struct PomodoroTitleBarTimer: View {
    let store: PomodoroStore
    /// Open/focus the Pomodoro workspace panel (wired to ContentView.openPanel).
    let onOpenPanel: () -> Void

    @State private var showingDashboard = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: store.menuBarIcon)
                .font(.caption)
            Text(store.titleBarText)
                .font(.caption.monospacedDigit())
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(stateTint.opacity(isHovered || showingDashboard ? 0.24 : 0.14))
        )
        .foregroundStyle(stateTint)
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onTapGesture { showingDashboard.toggle() }
        .popover(isPresented: $showingDashboard, arrowEdge: .bottom) {
            PomodoroDashboardPopover(store: store) {
                showingDashboard = false
                onOpenPanel()
            }
        }
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

// MARK: - Omarchy-Style Dashboard Popover
//
// The pomarchy walker dashboard, dropped down from the title-bar clock:
//
//   FOCUS                                                        ⚙︎
//   Make this block count
//   WORKING ON  [ What are you focusing on?                    ]
//                 ╭──────────╮
//                 │  25:00   │   circular countdown ring
//                 │  READY   │
//                 ╰──────────╯
//               FOCUS CYCLE  ○ ○ ○ ○
//   [ Focus ]   Short break    Long break      ← phase tabs
//        ↺      [ ▶ Start ]        ⏭            ← reset / start-pause / skip
//   ┌──────────────────────────────────────┐
//   │  0 sessions today  |  0 focused min  │
//   └──────────────────────────────────────┘

private struct PomodoroDashboardPopover: View {
    @Bindable var store: PomodoroStore
    /// Open/focus the full workspace panel (escape hatch from the popover).
    let onOpenPanel: () -> Void

    /// Which phase tab is previewed while idle (the ring shows its duration).
    @State private var selectedTab: PomodoroStore.Phase = .work
    @State private var showSettings = false

    /// The phase the dashboard is presenting: the live phase while running,
    /// the tab selection while idle (Omarchy's 1/2/3 phase preview).
    private var displayPhase: PomodoroStore.Phase {
        store.phase == .idle ? selectedTab : store.phase
    }

    private var displayTime: String {
        if store.phase == .idle {
            return PomodoroStore.formatted(TimeInterval(store.configuredMinutes(for: selectedTab) * 60))
        }
        return PomodoroStore.formatted(store.remaining)
    }

    private var displayProgress: Double {
        store.phase == .idle ? 0 : store.progress
    }

    private var displayTint: Color {
        switch displayPhase {
        case .idle: return .secondary
        case .work: return store.isPaused ? .orange : .accentColor
        case .shortBreak, .longBreak: return .green
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            workingOn
            ring
            cycleDots
            phaseTabs
            controls
            statsFooter
            if showSettings { settingsGrid }
            openPanelLink
        }
        .padding(18)
        .frame(width: 340)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayPhase == .idle ? "FOCUS" : displayPhase.displayName.uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(displayTint)
                Text("Make this block count")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation { showSettings.toggle() }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(showSettings ? Color.accentColor : .secondary)
            .help("Durations — focus / break / long break / cadence")
        }
    }

    private var workingOn: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WORKING ON")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("What are you focusing on?", text: $store.currentLabel)
                .textFieldStyle(.roundedBorder)
                .disabled(store.phase != .idle && store.phase != .work)
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 9)
            Circle()
                .trim(from: 0, to: displayProgress)
                .stroke(displayTint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: displayProgress)
            VStack(spacing: 2) {
                Text(displayTime)
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: displayTime)
                Text(store.statusWord.uppercased())
                    .font(.caption2.weight(.medium))
                    .tracking(2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 148, height: 148)
        .padding(.vertical, 2)
    }

    private var cycleDots: some View {
        VStack(spacing: 4) {
            Text("FOCUS CYCLE")
                .font(.caption2.weight(.medium))
                .tracking(1)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<store.cycleDots.total, id: \.self) { index in
                    Circle()
                        .strokeBorder(index <= store.cycleDots.done
                                      ? Color.accentColor : Color.secondary.opacity(0.5),
                                      lineWidth: 2)
                        .frame(width: 11, height: 11)
                }
            }
        }
    }

    private var phaseTabs: some View {
        HStack(spacing: 0) {
            phaseTab(.work, title: "Focus")
            phaseTab(.shortBreak, title: "Short break")
            phaseTab(.longBreak, title: "Long break")
        }
        .disabled(store.phase != .idle)
        .help(store.phase == .idle
              ? "Choose which timer Start begins"
              : "Phase switching is available while idle — reset to change phases")
    }

    private func phaseTab(_ phase: PomodoroStore.Phase, title: String) -> some View {
        let isSelected = displayPhase == phase
        return Button {
            selectedTab = phase
        } label: {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.secondary.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            // Reset (Omarchy's R)
            Button { store.stop() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(store.phase == .idle)
            .help("Reset to idle")

            // Start / Pause / Resume (Omarchy's SPACE)
            Button {
                centerButtonAction()
            } label: {
                Label(centerButtonTitle, systemImage: centerButtonIcon)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(displayTint)

            // Skip (Omarchy's S)
            Button { store.skipPhase() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(store.phase == .idle)
            .help("Skip to the next phase")
        }
    }

    private var centerButtonTitle: String {
        switch store.phase {
        case .idle: return "Start"
        case .work, .shortBreak, .longBreak: return store.isPaused ? "Resume" : "Pause"
        }
    }

    private var centerButtonIcon: String {
        switch store.phase {
        case .idle: return "play.fill"
        case .work, .shortBreak, .longBreak: return store.isPaused ? "play.fill" : "pause.fill"
        }
    }

    private func centerButtonAction() {
        switch store.phase {
        case .idle:
            switch selectedTab {
            case .work, .idle: store.startWork()
            case .shortBreak: store.startBreak()
            case .longBreak: store.startLongBreak()
            }
        case .work, .shortBreak, .longBreak:
            store.isPaused ? store.resume() : store.pause()
        }
    }

    private var statsFooter: some View {
        let stats = store.todayStats()
        return HStack(spacing: 10) {
            Text("\(stats.sessions) sessions today")
            Text("|").foregroundStyle(.quaternary)
            Text("\(stats.focusMinutes) focused minutes")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Inline durations — pomarchy's config.toml, live-editable (persisted).
    private var settingsGrid: some View {
        HStack(spacing: 14) {
            PopoverDurationStepper(title: "Focus", minutes: true,
                                   value: Binding(get: { store.workMinutes },
                                                  set: { store.workMinutes = $0 }),
                                   range: 1...240)
            PopoverDurationStepper(title: "Break", minutes: true,
                                   value: Binding(get: { store.shortBreakMinutes },
                                                  set: { store.shortBreakMinutes = $0 }),
                                   range: 1...60)
            PopoverDurationStepper(title: "Long", minutes: true,
                                   value: Binding(get: { store.longBreakMinutes },
                                                  set: { store.longBreakMinutes = $0 }),
                                   range: 1...120)
            PopoverDurationStepper(title: "Every", minutes: false,
                                   value: Binding(get: { store.cyclesBeforeLongBreak },
                                                  set: { store.cyclesBeforeLongBreak = $0 }),
                                   range: 2...8)
        }
        .padding(.top, 2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var openPanelLink: some View {
        Button("Open Pomodoro Panel…", action: onOpenPanel)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, -4)
    }
}

/// Compact labeled stepper for one duration in the popover's settings grid.
private struct PopoverDurationStepper: View {
    let title: String
    let minutes: Bool
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Stepper(value: $value, in: range) {
                Text("\(value)\(minutes ? "m" : "")")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 30)
            }
        }
    }
}
