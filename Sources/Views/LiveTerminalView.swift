import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Live Terminal View
//
// A genuinely interactive terminal: a real login shell attached to a real
// pseudo-terminal (PTY), full VT100/xterm emulation (ANSI colors, cursor
// movement, interactive programs like `vim`/`less`/`top`, tab completion —
// everything a normal terminal does), via SwiftTerm's `LocalProcessTerminalView`.
//
// This is deliberately separate from `AgentCommandLogView` (the read-only
// record of commands the agent has run via `execute_command`) — the agent's
// tool needs a reliable, structured exit-code/stdout/stderr result to reason
// about, which a live shared PTY stream can't cleanly provide. See
// `TerminalView`, which hosts both as tabs in one panel.
struct LiveTerminalView: NSViewRepresentable {

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        theme(view)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        view.startProcess(executable: shell, args: ["-l"], currentDirectory: NSHomeDirectory())
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Nothing to sync from SwiftUI state — the shell process is
        // long-running and owns its own content entirely.
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func theme(_ view: LocalProcessTerminalView) {
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1.0)
        view.caretColor = NSColor(red: 0.20, green: 0.80, blue: 0.45, alpha: 1.0)
    }

    /// Handles `LocalProcessTerminalViewDelegate` callbacks. Title changes and
    /// cwd tracking aren't surfaced anywhere yet (the panel's own header
    /// already shows a static "Terminal" title) — kept as a no-op home for
    /// them so they're easy to wire up later if needed.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        // Disambiguated from SwiftMaestro's own `TerminalView` (the panel
        // struct in this same module) — this is SwiftTerm's engine type.
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {}
    }
}
