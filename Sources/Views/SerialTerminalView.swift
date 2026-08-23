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
//
// The terminal NSView + serial session are pooled in TerminalPaneRegistry by
// pane ID so SwiftUI layout churn (splits, theme changes) never kills the
// link; only explicit pane/tab close terminates it.

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
        let pane = paneID
        let tab = tabID
        return TerminalPaneRegistry.shared.serialView(for: pane ?? UUID()) {
            let view = TappedTerminalView(frame: .zero)
            view.triggerPaneID = pane
            view.triggerTabID = tab
            let proxy = SerialTerminalDelegate(view: view)
            view.delegateProxy = proxy
            view.terminalDelegate = proxy
            applyTheme(to: view)

            do {
                view.serialSession = try SerialSession(device: device, baud: baud) { bytes in
                    // Triggers see the raw stream before rendering.
                    if let pane, let tab {
                        TerminalTriggerEngine.shared.processOutput(ArraySlice(bytes), pane: pane, tab: tab)
                    }
                    // Read pump thread → main; feed is main-thread only.
                    DispatchQueue.main.async { [weak view] in
                        view?.feed(byteArray: ArraySlice(bytes))
                    }
                }
            } catch {
                view.feed(text: "\(error.localizedDescription)\r\nClose this tab, check the board, and try again.\r\n")
            }
            return view
        }
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

    static func dismantleNSView(_ nsView: SwiftTerm.TerminalView, coordinator: ()) {
        // Deliberately NOT closing the serial session: the pane registry owns
        // the lifecycle; SwiftUI tears this view down on every split/theme
        // change and the board link must survive.
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
}
