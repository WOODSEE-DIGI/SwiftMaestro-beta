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

    @State private var tab: Tab = .live

    /// One live shell tab: its own PTY + process. All stay mounted in a
    /// ZStack so background shells keep running while hidden.
    struct ShellTab: Identifiable, Hashable {
        let id = UUID()
        var title: String
        /// nil = login shell; set = custom process (e.g. serial screen session)
        var launchCommand: String? = nil
    }

    @State private var shells: [ShellTab] = [ShellTab(title: "Shell 1")]
    @State private var activeShell: UUID?
    @State private var showDisplaySettings = false
    @State private var terminalSettings = TerminalSettings.shared

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
                        LiveTerminalView(launchCommand: shellTab.launchCommand)
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
    }

    private var activeShellID: UUID? {
        activeShell ?? shells.first?.id
    }

    /// Shell tab strip — visible, labeled chips (no cryptic icons): each is
    /// a live process. "New Shell" opens another login shell; × terminates it.
    /// Serial opens a `screen` session to a USB-serial board (Arduino etc.).
    /// Display customizes font/colors for every shell.
    private var shellTabStrip: some View {
        HStack(spacing: 6) {
            ForEach(shells) { shellTab in
                let isActive = shellTab.id == activeShellID
                HStack(spacing: 6) {
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
                        .help("Close \(shellTab.title) (terminates its process)")
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
                .onTapGesture { activeShell = shellTab.id }
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

    private var nextShellNumber: Int {
        var n = 1
        let existing = Set(shells.map(\.title))
        while existing.contains("Shell \(n)") { n += 1 }
        return n
    }

    /// USB-serial board picker (Arduino, ESP32, CH340, FTDI, …). Selecting a
    /// board + baud opens a new tab running `screen` on the device — the
    /// battle-tested serial monitor path. End with Ctrl-A then \\ inside
    /// the session, or just close the tab.
    private var serialMenu: some View {
        Menu {
            let devices = Self.serialDevices()
            if devices.isEmpty {
                Text("No USB-serial boards found")
                Text("Plug in an Arduino/ESP32 and reopen this menu")
            } else {
                ForEach(devices, id: \.self) { device in
                    Menu(device) {
                        ForEach(Self.serialBaudRates, id: \.self) { baud in
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
        .help("Connect to an Arduino/ESP32 or other USB-serial board via screen(1)")
    }

    static let serialBaudRates: [Int] = [9600, 19200, 38400, 57600, 74880, 115200, 230400]

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
        let tab = ShellTab(title: short, launchCommand: "exec screen \(device) \(baud)")
        shells.append(tab)
        activeShell = tab.id
    }

    private func closeShell(_ id: UUID) {
        guard let index = shells.firstIndex(where: { $0.id == id }) else { return }
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
