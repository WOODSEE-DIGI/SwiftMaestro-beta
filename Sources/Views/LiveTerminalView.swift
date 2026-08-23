import SwiftUI
import SwiftTerm

// A genuinely interactive shell inside the panel: a real local
// pseudo-terminal (PTY), full VT100/xterm emulation (ANSI colors, cursor
// movement, alternate screen, scrollback — everything a normal terminal
// does), via SwiftTerm's `LocalProcessTerminalView`.
//
// Each instance owns its own shell process (or a custom launch command,
// e.g. a serial `screen` session for Arduino). This view is deliberately
// separate from the agent `execute_command` path — an agent tool needs a
// reliable, structured exit-code/stdout/stderr result to reason about,
// which a live shared PTY byte stream can't cleanly provide. See
// ShellExecutionService for the agent side.
//
// Appearance comes from TerminalSettings.shared and re-applies live when
// the user changes font/colors in the Display popover.

struct LiveTerminalView: NSViewRepresentable {

    /// Optional command replacing the default login shell — used by serial
    /// tabs (e.g. "exec screen /dev/tty.usbmodem101 115200").
    var launchCommand: String?

    @State private var settings = TerminalSettings.shared

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        applyTheme(to: view)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let launchCommand {
            view.startProcess(executable: shell, args: ["-l", "-c", launchCommand], currentDirectory: NSHomeDirectory())
        } else {
            view.startProcess(executable: shell, args: ["-l"], currentDirectory: NSHomeDirectory())
        }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Reading settings properties here re-registers observation, so
        // font/color edits in the Display popover re-theme open shells live
        // (display-only; the running process is untouched).
        _ = settings.fontSize
        _ = settings.fontName
        _ = settings.foregroundHex
        _ = settings.backgroundHex
        _ = settings.cursorHex
        applyTheme(to: nsView)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func applyTheme(to view: LocalProcessTerminalView) {
        view.font = settings.font
        view.nativeBackgroundColor = settings.backgroundColor
        view.nativeForegroundColor = settings.foregroundColor
        view.caretColor = settings.cursorColor
    }

    /// Handles `LocalProcessTerminalViewDelegate` callbacks. Title changes and
    /// size changes are surfaced to SwiftTerm; nothing here needs to escape
    /// into SwiftUI state.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        // Disambiguated from SwiftMaestro's own `TerminalView` (the panel
        // struct in this same module) — this is SwiftTerm's engine type.
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {}
    }
}
