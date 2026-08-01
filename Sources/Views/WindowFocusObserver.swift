import SwiftUI
#if os(macOS)
import AppKit
#endif
import os

#if os(macOS)
private let focusLog = OSLog(subsystem: "com.woodseedigi.swiftmaestro", category: "WindowFocus")

/// Observes a `Notification.Name` and calls `makeKeyAndOrderFront` on the
/// hosting `NSWindow` whenever the notification's object matches the panel
/// identified by `match`. This lets a sidebar click bring an already-open
/// floating window to the front instead of silently leaving it behind other
/// windows.
struct WindowFocusObserver: NSViewRepresentable {
    let name: Notification.Name
    let match: (Any?) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(name: name, match: match)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private let name: Notification.Name
        private let match: (Any?) -> Bool
        private weak var view: NSView?
        private var observer: NSObjectProtocol?

        init(name: Notification.Name, match: @escaping (Any?) -> Bool) {
            self.name = name
            self.match = match
        }

        func attach(to view: NSView) {
            guard view !== self.view else { return }
            self.view = view
            os_log("WindowFocusObserver attached for %{public}@", log: focusLog, type: .info, name.rawValue)
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                let kindString = (note.object as? WorkspacePanelKind).map { String(describing: $0) } ?? "nil"
                os_log("WindowFocusObserver received %{public}@, match=%{public}d, hasWindow=%{public}d", log: focusLog, type: .info, kindString, self.match(note.object), self.view?.window != nil)
                guard self.match(note.object) else { return }
                guard let window = self.view?.window else { return }
                // Activating the app is required when the window is behind
                // another app; `makeKeyAndOrderFront` alone only reorders within
                // the current app if it is not active.
                os_log("WindowFocusObserver window=%{public}@ isVisible=%{public}d isKey=%{public}d level=%{public}ld", log: focusLog, type: .info, window.title ?? "<no title>", window.isVisible, window.isKeyWindow, window.level.rawValue)
                // `makeKeyAndOrderFront` alone can be ignored if the app is not
                // active or the window is behind another window. `orderFrontRegardless`
                // orders the window to the front regardless of activation state,
                // then we make it key.
                os_log("WindowFocusObserver ordering front regardless", log: focusLog, type: .info)
                window.orderFrontRegardless()
                os_log("WindowFocusObserver making key and ordering front", log: focusLog, type: .info)
                window.makeKeyAndOrderFront(nil)
            }
        }

        func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            view = nil
        }
    }
}
#endif
