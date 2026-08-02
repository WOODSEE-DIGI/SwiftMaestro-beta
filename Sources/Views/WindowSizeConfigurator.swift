import SwiftUI

#if os(macOS)
import AppKit

/// Applies a minimum and default content size to the hosting NSWindow.
///
/// SwiftUI's `WindowGroup` can restore tiny persisted window frames from a
/// previous session. This helper polls for the window and corrects obviously
/// unusable bounds without requiring a foreground activation or user-visible
/// window manipulation.
struct WindowSizeConfigurator: NSViewRepresentable {
    let minSize: CGSize
    let defaultSize: CGSize
    let backgroundColor: Color?

    func makeNSView(context: Context) -> NSView {
        let view = WindowObserverView()
        view.configurator = self
        view.environment = context.environment
        view.configure = { [weak view] in
            guard let view, let configurator = view.configurator,
                  let environment = view.environment else { return }
            let target = view.window ?? NSApp.mainWindow ?? NSApp.keyWindow
            configurator.configure(window: target, environment: environment)
        }
        view.startTimer()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowObserverView else { return }
        // Refresh the captured values — the closure created in makeNSView
        // would otherwise keep applying the ORIGINAL backgroundColor forever
        // (the window stayed dark after a light/dark flip).
        view.configurator = self
        view.environment = context.environment
        view.configure?()
    }

    private func configure(window: NSWindow?, environment: EnvironmentValues) {
        guard let window else { return }
        // SwiftUI's Settings scene builds a preferences-style window whose
        // styleMask omits `.resizable`, so `.windowResizability` alone never adds
        // resize handles. Insert it explicitly so the user can drag-resize.
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: minSize.width, height: minSize.height)

        // Prevent macOS from restoring a previously-saved tiny frame (e.g. after a
        // crash or a state-restoration bug). A blank autosave name stops the
        // window from reading any persisted frame, and we forcibly repair the frame
        // if it is already unusably small.
        window.setFrameAutosaveName("")

        let current = window.frame.size
        if current.width < minSize.width || current.height < minSize.height {
            let targetSize = NSSize(width: defaultSize.width, height: defaultSize.height)
            var frame = window.frame
            frame.origin.y += frame.size.height - targetSize.height
            frame.size = targetSize
            window.setFrame(frame, display: true, animate: false)
            window.center()
        }

        if let backgroundColor {
            let resolved = backgroundColor.resolve(in: environment)
            window.backgroundColor = NSColor(
                srgbRed: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.opacity))
        }
    }

    /// A lightweight NSView that re-runs its configuration closure whenever
    /// it moves into (or out of) a window, and also retries a few times via a
    /// short timer. SwiftUI's background representable may be created before
    /// its host NSWindow is assigned, and the main/key window can also be the
    /// correct target, so we check both paths.
    private final class WindowObserverView: NSView {
        var configure: (() -> Void)?
        var configurator: WindowSizeConfigurator?
        var environment: EnvironmentValues?
        private var timer: Timer?
        private var attempts = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure?()
        }

        func startTimer() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.attempts += 1
                self.configure?()
                if self.attempts >= 30 {
                    self.timer?.invalidate()
                    self.timer = nil
                }
            }
        }

    }
}
#endif
