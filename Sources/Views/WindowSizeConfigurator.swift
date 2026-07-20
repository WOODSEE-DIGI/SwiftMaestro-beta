import SwiftUI

#if os(macOS)
import AppKit

/// Applies a minimum and default content size to the hosting NSWindow.
///
/// SwiftUI's Settings scene can restore tiny persisted window frames. This
/// helper corrects obviously unusable bounds without requiring a foreground
/// activation or user-visible window manipulation.
struct WindowSizeConfigurator: NSViewRepresentable {
    let minSize: CGSize
    let defaultSize: CGSize
    let backgroundColor: Color?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(window: view.window, context: context) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: nsView.window, context: context) }
    }

    private func configure(window: NSWindow?, context: Context) {
        guard let window else { return }
        // SwiftUI's Settings scene builds a preferences-style window whose
        // styleMask omits `.resizable`, so `.windowResizability` alone never adds
        // resize handles. Insert it explicitly so the user can drag-resize.
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: minSize.width, height: minSize.height)

        let current = window.frame.size
        if current.width < minSize.width || current.height < minSize.height {
            window.setContentSize(NSSize(width: defaultSize.width, height: defaultSize.height))
            window.center()
        }

        if let backgroundColor {
            let resolved = backgroundColor.resolve(in: context.environment)
            window.backgroundColor = NSColor(
                srgbRed: CGFloat(resolved.red),
                green: CGFloat(resolved.green),
                blue: CGFloat(resolved.blue),
                alpha: CGFloat(resolved.opacity))
        }
    }
}
#endif
