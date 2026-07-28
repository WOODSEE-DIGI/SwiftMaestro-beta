import SwiftUI
import AppKit

/// A macOS button that calls `onPress` on mouse-down and `onRelease` on mouse-up.
///
/// This is needed because SwiftUI's `Button` + `DragGesture` does not reliably deliver
/// press-and-hold events on macOS, especially inside toolbars/control bars.
struct PTZPressButton: NSViewRepresentable {
    let icon: String
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = nil
        button.sendAction(on: [.leftMouseDown, .leftMouseUp, .mouseExited])
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        context.coordinator.onPress = onPress
        context.coordinator.onRelease = onRelease
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPress: onPress, onRelease: onRelease)
    }

    class Coordinator: NSObject {
        var onPress: () -> Void
        var onRelease: () -> Void

        init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
            self.onPress = onPress
            self.onRelease = onRelease
        }

        @objc func press() {
            onPress()
        }

        @objc func releaseAction() {
            onRelease()
        }
    }
}

/// A custom NSView that tracks mouse-down and mouse-up events.
///
/// NSButton has quirks when embedded in SwiftUI (action-on-mouse-up, delay, and event
/// routing). We use a plain NSView with a tracking area so we reliably get press and
/// release events regardless of where the cursor is when the mouse button is released.
final class PTZPressNSView: NSView {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var icon: String = ""

    private var isPressed = false
    private var trackingArea: NSTrackingArea?
    private var imageView: NSImageView?

    override var isFlipped: Bool { true }

    func setup() {
        guard imageView == nil else {
            installTrackingArea()
            return
        }
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let imageView = NSImageView(frame: bounds)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        addSubview(imageView)
        self.imageView = imageView
        installTrackingArea()
    }

    private func installTrackingArea() {
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setup()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        imageView?.frame = bounds
        installTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    func updateImage() {
        imageView?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
    }

    private func releaseIfNeeded() {
        guard isPressed else { return }
        isPressed = false
        print("[PTZPress] release fired for \(icon)")
        onRelease?()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        print("[PTZPress] press fired for \(icon)")
        onPress?()
    }

    override func mouseUp(with event: NSEvent) {
        releaseIfNeeded()
    }

    override func mouseExited(with event: NSEvent) {
        releaseIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        // Release if the user drags outside the view while the mouse is still down.
        if isPressed, !bounds.contains(convert(event.locationInWindow, from: nil)) {
            releaseIfNeeded()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Ignore right-clicks.
    }
}

/// Wrapper that uses the custom NSView subclass.
struct PTZPressButtonV2: NSViewRepresentable {
    let icon: String
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeNSView(context: Context) -> PTZPressNSView {
        let view = PTZPressNSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        view.setup()
        view.icon = icon
        view.onPress = onPress
        view.onRelease = onRelease
        view.updateImage()
        return view
    }

    func updateNSView(_ nsView: PTZPressNSView, context: Context) {
        nsView.icon = icon
        nsView.updateImage()
        nsView.onPress = onPress
        nsView.onRelease = onRelease
    }
}
