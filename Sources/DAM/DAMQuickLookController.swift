import AppKit
import Quartz

// MARK: - MaestroDAM Quick Look Controller
//
// Bridges the DAM grid/list selection to the system Quick Look panel so a
// single tap of the spacebar shows the same floating preview Finder uses for
// images, videos, PDFs, audio, and documents.

@MainActor
final class DAMQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    static let shared = DAMQuickLookController()

    // The data source methods are called by AppKit on the main thread, but
    // the Objective-C protocol is not annotated as MainActor, so they are
    // declared `nonisolated`. The URL is only ever set/read on the main
    // thread; it is explicitly unchecked to satisfy the compiler.
    nonisolated(unsafe) private var previewURL: URL?

    /// Present the system Quick Look panel for `url`.
    func show(_ url: URL) {
        previewURL = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Dismiss the Quick Look panel if it is open.
    func close() {
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    /// Toggle the panel for the given URL.
    func toggle(_ url: URL) {
        if QLPreviewPanel.shared()?.isVisible == true {
            close()
        } else {
            show(url)
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL != nil ? 1 : 0
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
        guard let previewURL else { return NSURL() }
        return previewURL as NSURL
    }
}
