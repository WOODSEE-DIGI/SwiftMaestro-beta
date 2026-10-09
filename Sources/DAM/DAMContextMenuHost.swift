import AppKit
import SwiftUI

/// A lightweight AppKit-backed right-click menu host for SwiftUI rows.
///
/// SwiftUI's `.contextMenu` on folder rows inside a `List` with drag/drop and
/// custom selection bindings was causing an immediate spinning beachball on
/// macOS. This host wraps the SwiftUI content in an `NSView` whose
/// `menu(for:)` returns an `NSMenu` on demand, bypassing the SwiftUI bug
/// entirely while preserving normal left-click/tap/drag behaviour.
struct DAMContextMenuHost<Content: View>: NSViewRepresentable {
    @ViewBuilder let content: () -> Content
    let buildMenu: (ContextMenuNSView) -> NSMenu

    func makeNSView(context: Context) -> ContextMenuNSView {
        let host = ContextMenuNSView()
        host.buildMenu = buildMenu

        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: host.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        return host
    }

    func updateNSView(_ nsView: ContextMenuNSView, context: Context) {
        guard let hostingView = nsView.subviews.first as? NSHostingView<Content> else { return }
        hostingView.rootView = content()
        nsView.buildMenu = buildMenu
    }
}

/// Thin wrapper that lets an `NSMenuItem` carry a Swift closure.
final class ContextMenuAction: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
}

/// Container view that builds an `NSMenu` on right-click and forwards left
/// clicks to the embedded SwiftUI content.
final class ContextMenuNSView: NSView {
    var buildMenu: ((ContextMenuNSView) -> NSMenu)?

    /// Holds the action wrappers alive while the menu is open. Cleared each
    /// time a new menu is built so closures are never stale.
    private var actionObjects: [ContextMenuAction] = []

    override func menu(for event: NSEvent) -> NSMenu? {
        actionObjects.removeAll()
        return buildMenu?(self)
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ContextMenuAction else { return }
        action.closure()
    }

    /// Convenience factory for menu items backed by closures.
    func item(
        title: String,
        keyEquivalent: String = "",
        imageName: String? = nil,
        color: NSColor? = nil,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let wrapper = ContextMenuAction(action)
        actionObjects.append(wrapper)
        let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: keyEquivalent)
        item.target = self
        item.representedObject = wrapper
        if let imageName {
            var image = NSImage(systemSymbolName: imageName, accessibilityDescription: title)
            if let color, let paletteImage = image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [color])
            ) {
                image = paletteImage
            }
            item.image = image
        }
        return item
    }

    func separator() -> NSMenuItem {
        NSMenuItem.separator()
    }
}
