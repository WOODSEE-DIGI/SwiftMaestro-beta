import AppKit
import Quartz

// MARK: - MaestroDAM Quick Look Panel Controller
//
// Presents a Finder-style spacebar preview in a dedicated floating panel.
// Uses QLPreviewView (not QLPreviewPanel) to avoid the responder-chain and
// data-source lifetime issues that come with the shared system panel.

@MainActor
final class DAMQuickLookPanelController {

    static let shared = DAMQuickLookPanelController()

    private var panel: NSPanel?

    private init() {}

    /// Show the preview panel for `url`, or close it if it is already visible.
    func toggle(for url: URL) {
        if let panel, panel.isVisible {
            close()
            return
        }
        show(for: url)
    }

    /// Always show the preview panel for `url`, replacing any existing preview.
    /// Use this for toolbar/menu actions where the intent is explicitly to open.
    func show(for url: URL) {
        close()
        present(for: url)
    }

    /// Dismiss the preview panel.
    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func present(for url: URL) {
        let previewView = QLPreviewView(frame: .zero)
        previewView?.previewItem = url as NSURL
        previewView?.shouldCloseWithWindow = true

        let contentView = NSView()
        if let previewView {
            previewView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(previewView)
            NSLayoutConstraint.activate([
                previewView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                previewView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                previewView.topAnchor.constraint(equalTo: contentView.topAnchor),
                previewView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.title = url.lastPathComponent
        newPanel.contentView = contentView
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)

        panel = newPanel
    }
}
