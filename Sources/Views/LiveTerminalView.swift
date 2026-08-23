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

    /// Optional command replacing the default login shell.
    var launchCommand: String?

    /// Per-tab preset override; nil follows the global TerminalSettings.
    var presetOverride: TerminalSettings.Preset? = nil

    /// Trigger-engine wiring: paneID keys the output line buffer, tabID is
    /// what gets badged when a trigger matches.
    var paneID: UUID?
    var tabID: UUID?

    @State private var settings = TerminalSettings.shared

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = TappedLocalProcessTerminalView(frame: .zero)
        view.triggerPaneID = paneID
        view.triggerTabID = tabID
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
        _ = settings.scrollbackLines
        _ = settings.paletteName
        applyTheme(to: nsView)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func applyTheme(to view: LocalProcessTerminalView) {
        if let presetOverride {
            view.font = NSFont(name: presetOverride.fontName, size: presetOverride.fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: presetOverride.fontSize, weight: .regular)
            if let bg = TerminalSettings.nsColor(fromHex: presetOverride.backgroundHex) { view.nativeBackgroundColor = bg }
            if let fg = TerminalSettings.nsColor(fromHex: presetOverride.foregroundHex) { view.nativeForegroundColor = fg }
            if let cursor = TerminalSettings.nsColor(fromHex: presetOverride.cursorHex) { view.caretColor = cursor }
        } else {
            view.font = settings.font
            view.nativeBackgroundColor = settings.backgroundColor
            view.nativeForegroundColor = settings.foregroundColor
            view.caretColor = settings.cursorColor
        }
        view.changeScrollback(settings.scrollbackLines)
        if let palette = settings.paletteColors {
            view.installColors(palette)
        }
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
