import SwiftUI

// MARK: - Terminal View

/// A terminal-style view showing real-time shell command execution logs.
/// Appears as a right-side panel in the chat view.
struct TerminalView: View {

    @ObservedObject private var logStore = ShellLogStore.shared
    @State private var autoScroll = true
    @State private var selectedEntry: ShellLogEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            terminalHeader
            Divider()
            // Log entries
            if logStore.entries.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .frame(minWidth: 360, idealWidth: 480)
        .background(Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)))
    }

    // MARK: - Header

    private var terminalHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .foregroundStyle(.green)
            Text("Terminal")
                .font(.headline)
            Spacer()

            Text("\(logStore.entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No commands yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Shell commands executed by agents will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(logStore.entries) { entry in
                        logEntryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: logStore.entries.count) { _, _ in
                if autoScroll, let last = logStore.entries.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    // MARK: - Log Entry Row

    @ViewBuilder
    private func logEntryRow(_ entry: ShellLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Command header
            HStack(spacing: 6) {
                Image(systemName: entry.statusIcon)
                    .foregroundStyle(entry.statusColor)
                    .font(.caption2)

                Text(formatTime(entry.timestamp))
                    .foregroundStyle(.secondary)
                    .font(.caption2)

                Text(entry.command)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                if entry.completed {
                    Spacer()
                    Text("\(entry.durationMs)ms")
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                }
            }
            .padding(.vertical, 4)

            // CWD
            if entry.completed {
                HStack(spacing: 4) {
                    Text("$")
                        .foregroundStyle(.green)
                    Text("cd \(entry.cwd)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)

                // Stdout
                if !entry.stdout.isEmpty {
                    outputBlock("stdout", text: entry.stdout, color: .white)
                }

                // Stderr
                if !entry.stderr.isEmpty {
                    outputBlock("stderr", text: entry.stderr, color: .red)
                }

                // Exit code
                if entry.exitCode != 0 {
                    HStack(spacing: 4) {
                        Text("exit:")
                            .foregroundStyle(.secondary)
                        Text("\(entry.exitCode)")
                            .foregroundStyle(entry.timedOut ? .yellow : .red)
                    }
                    .font(.caption2)
                }
            } else {
                // Still running
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Running...")
                        .foregroundStyle(.orange)
                }
                .font(.caption2)
            }

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 2)
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

    // MARK: - Output Block

    private func outputBlock(_ label: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("[\(label)]")
                .foregroundStyle(.secondary)
                .font(.caption2)
            Text(truncateOutput(text))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .padding(6)
        .background(Color.black.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func truncateOutput(_ text: String) -> String {
        let maxLines = 30
        let lines = text.components(separatedBy: .newlines)
        if lines.count <= maxLines { return text }
        return lines.prefix(maxLines).joined(separator: "\n")
            + "\n…(\(lines.count - maxLines) more lines)"
    }
}

// MARK: - Preview

#Preview {
    TerminalView()
        .frame(height: 400)
}
