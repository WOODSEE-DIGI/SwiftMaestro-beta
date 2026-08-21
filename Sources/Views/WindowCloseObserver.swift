import SwiftUI
import AppKit

#if os(macOS)
/// Invokes `onClose` exactly once when the hosting `NSWindow` actually closes
/// (red close button, Cmd+W, etc.) — SwiftUI's `.onDisappear` isn't reliably
/// tied to window-close specifically, so this observes
/// `NSWindow.willCloseNotification` directly instead. App termination does NOT
/// send willClose, so layouts survive a quit-with-windows-open.
struct WindowCloseObserver: NSViewRepresentable {
    let onClose: @MainActor @Sendable () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private let onClose: @MainActor @Sendable () -> Void
        private var observer: NSObjectProtocol?
        private weak var observedWindow: NSWindow?

        init(onClose: @escaping @MainActor @Sendable () -> Void) {
            self.onClose = onClose
        }

        func attach(to window: NSWindow?) {
            guard let window, window !== observedWindow else { return }
            detach()
            observedWindow = window
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [onClose] _ in
                Task { @MainActor in
                    onClose()
                }
            }
        }

        func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            observedWindow = nil
        }
    }
}
#endif
