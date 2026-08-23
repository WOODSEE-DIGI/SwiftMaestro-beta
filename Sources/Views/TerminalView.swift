import SwiftUI

// MARK: - Terminal View
//
// The top-level Terminal panel — a genuinely interactive shell (real PTY,
// full VT100/ANSI emulation via SwiftTerm) and a read-only record of what
// agents have executed via `execute_command`, as two tabs in one panel.
// They're kept separate rather than merged into one view: the agent's tool
// needs a reliable, structured exit-code/stdout/stderr result to reason
// about, which a live shared PTY byte stream can't cleanly provide, so each
// gets the representation it actually needs.
struct TerminalView: View {

    private enum Tab: String, CaseIterable, Identifiable {
        case live = "Live Terminal"
        case agentLog = "Agent Log"
        var id: String { rawValue }
    }

    /// One terminal tab. Panes form a recursive split tree (iTerm2-style):
    /// every leaf is its own independent PTY process or serial link, and any
    /// leaf can be split again. Split/close act on the FOCUSED pane (tracked
    /// via the terminal views' first-responder hook).
    struct ShellTab: Identifiable, Hashable {
        enum PaneKind: Hashable {
            /// Login shell (nil command) or a custom command tab.
            case shell(command: String?)
            /// Native USB-serial link (Arduino, ESP32, …) via SerialSession.
            case serial(device: String, baud: Int)
        }

        struct Pane: Identifiable, Hashable {
            let id = UUID()
            var kind: PaneKind
        }

        /// Binary split tree. .horizontal = side-by-side, .vertical = stacked.
        indirect enum PaneNode: Hashable {
            case leaf(Pane)
            case split(Axis, PaneNode, PaneNode)

            var leafCount: Int {
                switch self {
                case .leaf: return 1
                case .split(_, let first, let second): return first.leafCount + second.leafCount
                }
            }

            var firstLeaf: Pane? {
                switch self {
                case .leaf(let pane): return pane
                case .split(_, let first, _): return first.firstLeaf
                }
            }

            var allPanes: [Pane] {
                switch self {
                case .leaf(let pane): return [pane]
                case .split(_, let first, let second): return first.allPanes + second.allPanes
                }
            }

            /// Return a new tree with the given leaf split into two.
            func splitting(_ id: UUID, axis: Axis, newPane: Pane) -> PaneNode {
                switch self {
                case .leaf(let pane):
                    guard pane.id == id else { return self }
                    return .split(axis, .leaf(pane), .leaf(newPane))
                case .split(let a, let first, let second):
                    return .split(a, first.splitting(id, axis: axis, newPane: newPane),
                                  second.splitting(id, axis: axis, newPane: newPane))
                }
            }

            /// Return a new tree with the given leaf removed; its former
            /// sibling subtree collapses into the freed space.
            func removing(_ id: UUID) -> PaneNode {
                switch self {
                case .leaf:
                    return self // leaf removal is handled by its parent split
                case .split(let axis, let first, let second):
                    if case .leaf(let pane) = first, pane.id == id { return second }
                    if case .leaf(let pane) = second, pane.id == id { return first }
                    return .split(axis, first.removing(id), second.removing(id))
                }
            }
        }

        let id = UUID()
        var title: String
        var root: PaneNode
        /// Per-tab TerminalSettings preset name; nil follows the global settings.
        var presetName: String?

        init(title: String, kind: PaneKind = .shell(command: nil)) {
            self.title = title
            self.root = .leaf(Pane(kind: kind))
            self.presetName = nil
        }
    }

    @State private var tab: Tab = .live
    @State private var shells: [ShellTab] = [ShellTab(title: "Shell 1")]
    @State private var activeShell: UUID?
    @State private var showDisplaySettings = false
    @State private var showTriggerSettings = false
    @State private var terminalSettings = TerminalSettings.shared
    @State private var triggerEngine = TerminalTriggerEngine.shared
    /// Tabs with an unread trigger alert; cleared when the tab is focused.
    @State private var badgedTabs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == .live {
                shellTabStrip
                Divider()
            }
            switch tab {
            case .live:
                ZStack {
                    ForEach(shells) { shellTab in
                        paneContainer(for: shellTab)
                            .opacity(shellTab.id == activeShellID ? 1 : 0)
                            .allowsHitTesting(shellTab.id == activeShellID)
                    }
                }
            case .agentLog:
                AgentCommandLogView()
            }
        }
        .frame(minWidth: 360, idealWidth: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { registerTriggerBadgeHandler() }
    }

    private var activeShellID: UUID? {
        get { activeShell ?? shells.first?.id }
    }

    /// Focus a tab and clear its trigger badge.
    private func activateTab(_ id: UUID) {
        activeShell = id
        badgedTabs.remove(id)
    }

    private func registerTriggerBadgeHandler() {
        triggerEngine.onBadge = { tabID, _, _ in
            if tabID != activeShellID {
                badgedTabs.insert(tabID)
            }
        }
    }

    private var activeTabIndex: Int? {
        shells.firstIndex(where: { $0.id == activeShellID })
    }

    // MARK: - Panes (recursive split tree)

    @ViewBuilder
    private func paneContainer(for shellTab: ShellTab) -> some View {
        renderNode(shellTab.root, tabID: shellTab.id, presetName: shellTab.presetName)
    }

    /// Recursive tree render. Returns AnyView because Swift opaque result
    /// types cannot be recursive; the terminal NSViews themselves are pooled
    /// in TerminalPaneRegistry so this type erasure never costs a process.
    private func renderNode(_ node: ShellTab.PaneNode, tabID: UUID, presetName: String?) -> AnyView {
        switch node {
        case .leaf(let pane):
            return AnyView(terminalPane(pane, presetName: presetName, tabID: tabID))
        case .split(let axis, let first, let second):
            if axis == .horizontal {
                return AnyView(HStack(spacing: 0) {
                    renderNode(first, tabID: tabID, presetName: presetName)
                    Divider()
                    renderNode(second, tabID: tabID, presetName: presetName)
                })
            } else {
                return AnyView(VStack(spacing: 0) {
                    renderNode(first, tabID: tabID, presetName: presetName)
                    Divider()
                    renderNode(second, tabID: tabID, presetName: presetName)
                })
            }
        }
    }

    @ViewBuilder
    private func terminalPane(_ pane: ShellTab.Pane, presetName: String?, tabID: UUID) -> some View {
        let preset = presetName.flatMap { name in
            TerminalSettings.presets.first(where: { $0.name == name })
        }
        switch pane.kind {
        case .shell(let command):
            LiveTerminalView(launchCommand: command, presetOverride: preset,
                             paneID: pane.id, tabID: tabID)
        case .serial(let device, let baud):
            SerialTerminalView(device: device, baud: baud, presetOverride: preset,
                               paneID: pane.id, tabID: tabID)
        }
    }

    /// Split a specific pane of the active tab (explicitly targeted from the
    /// Split menu — no invisible focus rules).
    private func splitPane(_ paneID: UUID, axis: Axis) {
        guard let idx = activeTabIndex else { return }
        shells[idx].root = shells[idx].root.splitting(
            paneID, axis: axis, newPane: ShellTab.Pane(kind: .shell(command: nil)))
    }

    /// Close a specific pane; its sibling subtree collapses into the space.
    /// The registry terminates the pane's process explicitly — SwiftUI layout
    /// teardown deliberately does not.
    private func closePane(_ paneID: UUID) {
        guard let idx = activeTabIndex, shells[idx].root.leafCount > 1 else { return }
        TerminalTriggerEngine.shared.clearPane(paneID)
        shells[idx].root = shells[idx].root.removing(paneID)
        TerminalPaneRegistry.shared.terminate(paneID)
    }

    /// Display label for a pane in Split menus: position + kind.
    private func paneLabel(_ pane: ShellTab.Pane, index: Int) -> String {
        switch pane.kind {
        case .shell(let command):
            if let command, command.contains("tmux") { return "Pane \(index + 1) (tmux)" }
            if command != nil { return "Pane \(index + 1) (command)" }
            return "Pane \(index + 1) (shell)"
        case .serial(let device, let baud):
            let short = device.replacingOccurrences(of: "/dev/tty.", with: "")
            return "Pane \(index + 1) (\(short) @ \(baud))"
        }
    }

    // MARK: - Tab strip

    /// Shell tab strip — visible, labeled chips (no cryptic icons). Right-click
    /// a chip for its per-tab profile (font/color preset) and close action.
    /// "New Shell" opens another login shell; Serial opens a native USB-serial
    /// link; Split runs two panes side-by-side or stacked in the active tab.
    private var shellTabStrip: some View {
        HStack(spacing: 6) {
            ForEach(shells) { shellTab in
                let isActive = shellTab.id == activeShellID
                HStack(spacing: 6) {
                    if badgedTabs.contains(shellTab.id) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .help("A trigger matched in this tab")
                    }
                    Text(shellTab.title)
                        .font(.caption.monospaced().weight(isActive ? .semibold : .regular))
                    if shells.count > 1 {
                        Button {
                            closeShell(shellTab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                        }
                        .buttonStyle(.plain)
                        .help("Close \(shellTab.title) (terminates its processes)")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { activateTab(shellTab.id) }
                .contextMenu {
                    Menu("Profile") {
                        Button(shellTab.presetName == nil ? "✓ Default (follow Display settings)" : "Default (follow Display settings)") {
                            setPreset(nil, for: shellTab.id)
                        }
                        Divider()
                        ForEach(TerminalSettings.presets, id: \.name) { preset in
                            Button(shellTab.presetName == preset.name ? "✓ \(preset.name)" : preset.name) {
                                setPreset(preset.name, for: shellTab.id)
                            }
                        }
                    }
                    if shellTab.root.leafCount > 1 {
                        Menu("Close Pane") {
                            ForEach(Array(shellTab.root.allPanes.enumerated()), id: \.element.id) { index, pane in
                                Button(paneLabel(pane, index: index)) { closePane(pane.id) }
                            }
                        }
                    }
                    if shells.count > 1 {
                        Divider()
                        Button("Close Tab") { closeShell(shellTab.id) }
                    }
                }
            }

            Button {
                let tab = ShellTab(title: "Shell \(nextShellNumber)")
                shells.append(tab)
                activeShell = tab.id
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                    Text("New Shell")
                        .font(.caption.monospaced())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open another terminal shell (separate process)")

            serialMenu
            splitMenu
            tmuxMenu

            Button {
                showTriggerSettings = true
            } label: {
                Text("Triggers (\(triggerEngine.triggers.filter(\.isEnabled).count))")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Regex rules that beep and/or badge a tab when output matches (iTerm2-style triggers)")
            .popover(isPresented: $showTriggerSettings) {
                TerminalTriggersView(engine: triggerEngine)
            }

            Button {
                showDisplaySettings = true
            } label: {
                Text("Display…")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Terminal font, size, and colors (applies to all shells)")
            .popover(isPresented: $showDisplaySettings) {
                TerminalDisplaySettingsView(settings: terminalSettings)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func setPreset(_ name: String?, for tabID: UUID) {
        guard let idx = shells.firstIndex(where: { $0.id == tabID }) else { return }
        shells[idx].presetName = name
    }

    private var nextShellNumber: Int {
        var n = 1
        let existing = Set(shells.map(\.title))
        while existing.contains("Shell \(n)") { n += 1 }
        return n
    }

    /// Split control with EXPLICIT pane targets (no invisible focus rules —
    /// you pick exactly which pane splits or closes). Panes split recursively;
    /// each is its own independent process, and splitting never kills the
    /// split pane's process (terminal views are pooled).
    private var splitMenu: some View {
        let panes = activeTabIndex.map { shells[$0].root.allPanes } ?? []
        let canClose = panes.count > 1
        return Menu {
            Menu("Split Right") {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    Button(paneLabel(pane, index: index)) { splitPane(pane.id, axis: .horizontal) }
                }
            }
            Menu("Split Down") {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    Button(paneLabel(pane, index: index)) { splitPane(pane.id, axis: .vertical) }
                }
            }
            Divider()
            Menu("Close Pane") {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    Button(paneLabel(pane, index: index)) { closePane(pane.id) }
                }
            }
            .disabled(!canClose)
        } label: {
            Text("Split")
                .font(.caption.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Split any pane right/down, or close one — each pane is its own process and survives splits")
    }

    // MARK: - tmux

    /// tmux sessions: attach to an existing one (survives tab closes and app
    /// restarts on the server side) or create a new named session. iTerm2
    /// uses tmux -CC control mode; we use plain attach/new — same persistence
    /// benefit without the control-mode protocol work.
    private var tmuxMenu: some View {
        Menu {
            if Self.tmuxBinary == nil {
                Text("tmux not installed")
                Text("brew install tmux, then reopen this menu")
            } else {
                Button("New Session (\(Self.defaultTmuxSession))") {
                    openTmux(session: Self.defaultTmuxSession, attachIfExists: true)
                }
                Divider()
                let sessions = Self.tmuxSessions()
                if sessions.isEmpty {
                    Text("No running tmux sessions")
                } else {
                    ForEach(sessions, id: \.self) { session in
                        Button("Attach: \(session)") {
                            openTmux(session: session, attachIfExists: false)
                        }
                    }
                }
            }
        } label: {
            Text("tmux")
                .font(.caption.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Attach to or create persistent tmux sessions (sessions survive tab closes)")
    }

    static let defaultTmuxSession = "main"

    static var tmuxBinary: String? {
        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Names of currently running tmux sessions (nil-safe, non-blocking).
    static func tmuxSessions() -> [String] {
        guard let binary = tmuxBinary else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["ls", "-F", "#{session_name}"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return [] }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private func openTmux(session: String, attachIfExists: Bool) {
        guard let binary = Self.tmuxBinary else { return }
        let command = attachIfExists
            ? "exec \(binary) new-session -A -s '\(session)'"
            : "exec \(binary) attach-session -t '\(session)'"
        let tab = ShellTab(title: "tmux:\(session)", kind: .shell(command: command))
        shells.append(tab)
        activateTab(tab.id)
    }

    /// USB-serial board picker (Arduino, ESP32, CH340, FTDI, …) — opens a tab
    /// with a NATIVE termios serial link (no screen subprocess). Unplugging
    /// the board or closing the tab ends the session cleanly.
    private var serialMenu: some View {
        Menu {
            let devices = Self.serialDevices()
            if devices.isEmpty {
                Text("No USB-serial boards found")
                Text("Plug in an Arduino/ESP32 and reopen this menu")
            } else {
                ForEach(devices, id: \.self) { device in
                    Menu(device) {
                        ForEach(SerialSession.supportedBauds, id: \.self) { baud in
                            Button("\(baud) baud") {
                                openSerial(device: device, baud: baud)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cable.connector")
                    .font(.caption.weight(.bold))
                Text("Serial")
                    .font(.caption.monospaced())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Connect to an Arduino/ESP32 or other USB-serial board (native link)")
    }

    /// USB-serial device nodes present in /dev right now.
    static func serialDevices() -> [String] {
        let prefixes = ["tty.usbmodem", "tty.usbserial", "tty.wchusbserial", "tty.SLAB_USBtoUART", "tty.usbserial-"]
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries
            .filter { name in prefixes.contains(where: { name.hasPrefix($0) }) }
            .sorted()
            .map { "/dev/\($0)" }
    }

    private func openSerial(device: String, baud: Int) {
        let short = device.replacingOccurrences(of: "/dev/tty.", with: "")
        let tab = ShellTab(title: short, kind: .serial(device: device, baud: baud))
        shells.append(tab)
        activeShell = tab.id
    }

    private func closeShell(_ id: UUID) {
        guard let index = shells.firstIndex(where: { $0.id == id }) else { return }
        for pane in shells[index].root.allPanes {
            TerminalTriggerEngine.shared.clearPane(pane.id)
            TerminalPaneRegistry.shared.terminate(pane.id)
        }
        badgedTabs.remove(id)
        shells.remove(at: index)
        if activeShell == id {
            activeShell = shells[min(index, shells.count - 1)].id
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(.green)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Agent Command Log
//
// A terminal-style view showing real-time shell command execution logs.
//
// Visual language borrowed from opencode's own tool/bash rendering
// (packages/tui/src/routes/session/index.tsx — `BlockTool`/`Shell`): each
// command is one continuous block accented by a single left border, a muted
// single-line `$ command` title, plain-text output directly beneath (no boxed
// [stdout]/[stderr] cards), and click-to-expand truncation for long output —
// instead of heavy per-entry cards with dividers and redundant `$ cd <cwd>`
// lines everywhere.
struct AgentCommandLogView: View {

    @ObservedObject private var logStore = ShellLogStore.shared
    @State private var autoScroll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logHeader
            Divider()
            if logStore.entries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
    }

    // MARK: - Header

    private var logHeader: some View {
        HStack(spacing: 6) {
            Text("\(logStore.entries.count) command\(logStore.entries.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()

            Button {
                autoScroll.toggle()
            } label: {
                Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .help(autoScroll ? "Auto-scroll ON" : "Auto-scroll OFF")

            Button {
                logStore.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Clear terminal log")
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("No commands yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(logStore.entries) { entry in
                        TerminalLogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
            }
            .onChange(of: logStore.entries.count) { _, _ in
                if autoScroll, let last = logStore.entries.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Log Entry Row

/// One command's block: a single left-border-accented block containing a
/// muted `$ command` title and its plain-text output — no separate stdout/
/// stderr boxes, no restated `$ cd <cwd>` line. Its own `View` (rather than a
/// helper method) so each entry keeps independent expand/collapse state.
private struct TerminalLogEntryRow: View {
    let entry: ShellLogEntry

    @State private var expanded = false

    /// Truncation thresholds mirroring opencode's `collapseToolOutput`
    /// (packages/tui/src/util/collapse-tool-output.ts): a generous line cap
    /// that keeps the scrollback scannable, with click-to-expand for the rest.
    private static let maxLines = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleLine

            if entry.completed {
                if !combinedOutput.isEmpty {
                    Text(limitedOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(entry.stderr.isEmpty ? Color.primary.opacity(0.85) : Color.red.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if collapsedOutput.overflow {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                    } label: {
                        Text(expanded ? "Click to collapse" : "Click to expand")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                if entry.exitCode != 0 {
                    Text("exit \(entry.exitCode)")
                        .font(.caption2)
                        .foregroundStyle(entry.timedOut ? .yellow : .red)
                }
            } else {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Running…")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(entry.statusColor.opacity(0.55))
                .frame(width: 2)
        }
        .contextMenu {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.command, forType: .string)
            }
            if !entry.stdout.isEmpty {
                Button("Copy Stdout") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.stdout, forType: .string)
                }
            }
            if !entry.stderr.isEmpty {
                Button("Copy Stderr") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.stderr, forType: .string)
                }
            }
        }
    }

    // MARK: - Title line

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: entry.statusIcon)
                .foregroundStyle(entry.statusColor)
                .font(.caption2)
            Text(formatTime(entry.timestamp))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text("$ \(entry.command)")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if entry.completed {
                Text("\(entry.durationMs)ms")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Output truncation

    /// stdout followed by stderr, joined the way a real shell would interleave
    /// them onto one stream (approximately — exact interleaving isn't
    /// preserved since they're captured on separate pipes).
    private var combinedOutput: String {
        var parts: [String] = []
        if !entry.stdout.isEmpty { parts.append(entry.stdout) }
        if !entry.stderr.isEmpty { parts.append(entry.stderr) }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var collapsedOutput: (output: String, overflow: Bool) {
        let lines = combinedOutput.components(separatedBy: .newlines)
        guard lines.count > Self.maxLines else { return (combinedOutput, false) }
        let preview = lines.prefix(Self.maxLines).joined(separator: "\n")
        return (preview + "\n…(\(lines.count - Self.maxLines) more lines)", true)
    }

    private var limitedOutput: String {
        expanded || !collapsedOutput.overflow ? combinedOutput : collapsedOutput.output
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    TerminalView()
        .frame(height: 400)
}
