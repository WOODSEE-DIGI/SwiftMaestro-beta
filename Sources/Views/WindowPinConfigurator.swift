import SwiftUI

#if os(macOS)
import AppKit

/// Keeps the hosting `NSWindow`'s level in sync with a pinned/unpinned toggle.
///
/// When `isPinned` is `true` the window floats above all other windows
/// (including other apps' — matches the standard "keep on top" behavior of
/// AppKit utility panels). When `false` it behaves like any normal document
/// window. This is opt-in per window and always defaults to `false` at each
/// call site — no floating window is pinned unless the user explicitly turns
/// it on for that specific window.
struct WindowPinConfigurator: NSViewRepresentable {
    let isPinned: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.level = isPinned ? .floating : .normal
    }
}
#endif
