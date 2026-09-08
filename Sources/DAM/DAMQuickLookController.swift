import AppKit
import Quartz

// MARK: - MaestroDAM Quick Look Controller
//
// Bridges the DAM grid/list selection to the system Quick Look panel so a
// single tap of the spacebar shows the same floating preview Finder uses for
// images, videos, PDFs, audio, and documents.

final class DAMQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {

    nonisolated(unsafe) static let shared = DAMQuickLookController()

    private var previewURL: URL?

    /// Present the system Quick Look panel for `url`.
    func show(_ url: URL) {
        Task { @MainActor [self] in
            previewURL = url
            guard let panel = QLPreviewPanel.shared() else { return }
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Dismiss the Quick Look panel if it is open.
    func close() {
        Task { @MainActor [self] in
            QLPreviewPanel.shared()?.orderOut(nil)
        }
    }

    /// Toggle the panel for the given URL.
    func toggle(_ url: URL) {
        Task { @MainActor [self] in
            if QLPreviewPanel.shared()?.isVisible == true {
                close()
            } else {
                show(url)
            }
        }
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
        guard let previewURL else { return NSURL() }
        return previewURL as NSURL
    }
}
