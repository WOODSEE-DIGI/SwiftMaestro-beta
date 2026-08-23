import SwiftUI
import SwiftTerm

// MARK: - Serial Terminal View
//
// A SwiftTerm terminal wired directly to a USB-serial board via SerialSession
// (native termios link — no screen(1) subprocess). Bytes from the board are
// fed into the terminal engine; keystrokes are written back to the board.
//
// Themed by TerminalSettings like every other terminal, with an optional
// per-tab preset override. Errors (unplugged board, permission) are rendered
// INTO the terminal so the user sees them in context rather than as an alert.

// Note: SwiftTerm.TerminalView is fully qualified throughout — this module
// has its own TerminalView (the panel struct), which would otherwise win
// name resolution.
struct SerialTerminalView: NSViewRepresentable {
    let device: String
    let baud: Int
    /// Per-tab preset override; nil follows the global TerminalSettings.
    var presetOverride: TerminalSettings.Preset?

    /// Trigger-engine wiring: paneID keys the output line buffer, tabID is
    /// what gets badged when a trigger matches.
    var paneID: UUID?
    var tabID: UUID?

    @State private var settings = TerminalSettings.shared

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        applyTheme(to: view)

        do {
            let pane = paneID
            let tab = tabID
            let session = try SerialSession(device: device, baud: baud) { bytes in
                // Triggers see the raw stream before rendering.
                if let pane, let tab {
                    TerminalTriggerEngine.shared.processOutput(ArraySlice(bytes), pane: pane, tab: tab)
                }
                // Read pump thread → main; feed is main-thread only.
                let terminalView = context.coordinator.terminalView
                DispatchQueue.main.async {
                    terminalView?.feed(byteArray: ArraySlice(bytes))
                }
            }
            context.coordinator.session = session
            context.coordinator.terminalView = view
        } catch {
            view.feed(text: "\(error.localizedDescription)\r\nClose this tab, check the board, and try again.\r\n")
        }
        return view
    }

    func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        // Re-register observation so Display… edits re-theme live.
        _ = settings.fontSize
        _ = settings.fontName
        _ = settings.foregroundHex
        _ = settings.backgroundHex
        _ = settings.cursorHex
        _ = settings.scrollbackLines
        _ = settings.paletteName
        applyTheme(to: nsView)
    }

    static func dismantleNSView(_ nsView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.session?.close()
        coordinator.session = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func applyTheme(to view: SwiftTerm.TerminalView) {
        if let presetOverride {
            view.font = NSFont(name: presetOverride.fontName, size: presetOverride.fontSize)
                ?? NSFont.monospacedSystemFont(ofSize: presetOverride.fontSize, weight: .regular)
            view.nativeBackgroundColor = TerminalSettings.nsColor(fromHex: presetOverride.backgroundHex) ?? view.nativeBackgroundColor
            view.nativeForegroundColor = TerminalSettings.nsColor(fromHex: presetOverride.foregroundHex) ?? view.nativeForegroundColor
            view.caretColor = TerminalSettings.nsColor(fromHex: presetOverride.cursorHex) ?? view.caretColor
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

    final class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        var session: SerialSession?
        weak var terminalView: SwiftTerm.TerminalView?

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        /// Keystrokes from the terminal → the board.
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            session?.send(Array(data))
        }
    }
}
