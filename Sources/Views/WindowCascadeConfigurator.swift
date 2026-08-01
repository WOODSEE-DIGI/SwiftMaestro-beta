import SwiftUI

#if os(macOS)
import AppKit

/// Cascades newly opened workspace-panel windows so they don't all stack on top
/// of each other. Uses NSWindow's built-in cascade behavior, starting from the
/// main window's top-left corner (or the top-left of the screen if there is no
/// main window).
struct WindowCascadeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op: cascade only on initial appearance.
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        FloatingWindowCascadeManager.shared.cascade(window: window)
    }
}

/// Tracks the next cascade point across workspace panel windows.
@MainActor
final class FloatingWindowCascadeManager {
    static let shared = FloatingWindowCascadeManager()

    /// Non-nil while a window is being cascaded; prevents re-entry from the
    /// same view's background modifier firing twice.
    private var cascadingWindow: ObjectIdentifier?
    private var cascadePoint: NSPoint?
    private var fallbackStart: NSPoint?

    private init() {}

    func cascade(window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard cascadingWindow != id else { return }
        cascadingWindow = id

        // Wait for SwiftUI to finish sizing the window, then apply cascade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
            guard let self, let window else { return }
            defer { self.cascadingWindow = nil }

            guard let screen = window.screen ?? NSScreen.main else { return }
            let visibleFrame = screen.visibleFrame

            // Start from the main window's top-left if we haven't cascaded yet.
            let startPoint: NSPoint
            if let cascadePoint = self.cascadePoint {
                startPoint = cascadePoint
            } else if let mainWindow = NSApp.mainWindow {
                startPoint = NSPoint(x: mainWindow.frame.minX, y: mainWindow.frame.maxY)
            } else {
                startPoint = NSPoint(x: visibleFrame.minX + 40, y: visibleFrame.maxY - 40)
            }

            // Use NSWindow's built-in cascade. If the computed point is off
            // screen, reset to the top-left of the visible frame.
            var nextPoint = window.cascadeTopLeft(from: startPoint)
            let windowFrame = window.frame
            if nextPoint.x + windowFrame.width > visibleFrame.maxX - 40
                || nextPoint.y - windowFrame.height < visibleFrame.minY + 40 {
                nextPoint = window.cascadeTopLeft(from: NSPoint(
                    x: visibleFrame.minX + 40,
                    y: visibleFrame.maxY - 40
                ))
            }

            self.cascadePoint = nextPoint
            // cascadeTopLeft(from:) only RETURNS the point — it never moves
            // the window. Without this call every panel window opens wherever
            // SwiftUI centers it (screen center = header halfway down).
            window.setFrameTopLeftPoint(nextPoint)
        }
    }
}
#endif
