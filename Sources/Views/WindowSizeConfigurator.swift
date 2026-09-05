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
        WindowObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowObserverView else { return }

        // Resolve any background color against the current environment now,
        // but defer the actual window mutation so we don't re-enter SwiftUI
        // layout/preference evaluation during this update pass.
        view.pendingBackgroundColor = backgroundColor.map { color in
            let resolved = color.resolve(in: context.environment)
            return NSColor(
                srgbRed: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.opacity)
            )
        }
        view.configurator = self

        DispatchQueue.main.async { [weak view] in
            view?.applyConfiguration()
        }
    }

    fileprivate func configure(window: NSWindow?, backgroundColor: NSColor?) {
        guard let window, !ConfiguredWindows.shared.contains(window) else { return }
        ConfiguredWindows.shared.add(window)

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
            window.backgroundColor = backgroundColor
        }
    }

    /// A lightweight NSView that re-runs its configuration closure whenever
    /// it moves into a window. The actual window mutation is always deferred
    /// to the next main-queue pass to avoid re-entrant SwiftUI updates during
    /// `NSHostingView.viewDidMoveToWindow()`.
    private final class WindowObserverView: NSView {
        fileprivate var configurator: WindowSizeConfigurator?
        fileprivate var pendingBackgroundColor: NSColor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.applyConfiguration()
            }
        }

        fileprivate func applyConfiguration() {
            guard let configurator, let window else { return }
            configurator.configure(window: window, backgroundColor: pendingBackgroundColor)
        }
    }
}

/// Tracks which windows have already been configured so the configurator is
/// idempotent even if `updateNSView` or `viewDidMoveToWindow` fire multiple
/// times. Weak references avoid keeping windows alive. All access is on the
/// main actor because window configuration always happens there.
@MainActor
private final class ConfiguredWindows {
    static let shared = ConfiguredWindows()
    private let table = NSHashTable<NSWindow>.weakObjects()

    private init() {}

    func contains(_ window: NSWindow) -> Bool {
        table.contains(window)
    }

    func add(_ window: NSWindow) {
        table.add(window)
    }
}
#endif
